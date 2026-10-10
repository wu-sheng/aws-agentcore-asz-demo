#!/usr/bin/env bash
# Tier-2: tear the whole environment down, and report what is gone.
#
#   ./scripts/down.sh [--yes] [--wait SECONDS]
#       Request deletion of everything, then wait (default 600s) for it to
#       finish. Every resource up.sh created is in OpenTofu state, including the
#       AgentCore runtime, the ECR repo (with its images) and EFS (with asz's
#       stored conversations). The runtime's log groups, which AWS creates
#       outside state, are deleted too. If the wait runs out, it prints what is
#       still in progress and exits 3; run it again later to finish.
#
#   ./scripts/down.sh check
#       Read-only. Lists what has been removed and what is still in progress.
#       Safe to run any time.
#
# Why it can take hours: AWS keeps AgentCore's network interfaces (type
# agentic_ai) in the agent's subnets after the runtime is deleted -- "up to 8
# hours" per the AgentCore VPC guide; in our run it took about 10. You cannot
# delete them yourself. Until they go, the VPC, its private subnets and the
# agent security group cannot be deleted. Those cost nothing; everything that
# bills is gone long before.
#
# Exit codes: 0 finished, 3 still in progress, 1 error / aborted.
set -euo pipefail
set -f  # resource addresses like aws_subnet.private[0] must not glob

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$ROOT/infra/terraform"
MANIFEST="$ROOT/.deploy/resources.txt"
LOG="$ROOT/.deploy/down.log"

MODE=down YES=0 WAIT=600
while [ $# -gt 0 ]; do
  case "$1" in
    check) MODE=check ;;
    --yes) YES=1 ;;
    --wait) WAIT="${2:?--wait needs seconds}"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

cd "$TF"
tofu init -input=false >/dev/null
REGION="$(tofu console <<<'var.aws_region' | tr -d '"')"
PROJECT="$(tofu console <<<'var.project_name' | tr -d '"')"
# Use the tfvars profile for the AWS CLI too, so tofu and aws act as one identity.
PROFILE="$(tofu console <<<'var.aws_profile == null ? "" : var.aws_profile' | tr -d '"')"
[ -z "$PROFILE" ] || export AWS_PROFILE="$PROFILE"
RUNTIME_NAME="$(echo "${PROJECT}_agent" | tr - _)"
RUNTIME_ID="$(tofu output -raw agent_runtime_id 2>/dev/null || true)"
# Fall back to the manifest once state no longer has it (e.g. a re-run).
if [ -z "$RUNTIME_ID" ] && [ -f "$MANIFEST" ]; then
  RUNTIME_ID="$(sed -n 's/^agent_runtime_id=//p' "$MANIFEST")"
fi
mkdir -p "$(dirname "$LOG")"

# --- probes -----------------------------------------------------------------
in_state() { tofu state list 2>/dev/null | grep -v '^data\.' || true; }

# Everything up.sh recorded as in state, so we can say what has been removed.
created() {
  [ -f "$MANIFEST" ] || return 0
  sed -n '/^# In OpenTofu state/,/^$/p' "$MANIFEST" | grep -v -e '^#' -e '^$' -e '^data\.' || true
}

vpc_id() {
  tofu state show -no-color aws_vpc.this 2>/dev/null \
    | sed -n 's/^ *id *= *"\(vpc-[^"]*\)".*/\1/p' | head -1
}

# AgentCore's network interfaces still in our VPC, if any.
agentcore_enis() {
  local vpc; vpc="$(vpc_id)"
  [ -n "$vpc" ] || return 0
  aws ec2 describe-network-interfaces --region "$REGION" --filters "Name=vpc-id,Values=$vpc" \
    --query "NetworkInterfaces[?InterfaceType=='agentic_ai'].NetworkInterfaceId" --output text
}

runtime_log_groups() {
  [ -n "$RUNTIME_ID" ] || return 0
  aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "/aws/bedrock-agentcore/runtimes/$RUNTIME_ID" \
    --query 'logGroups[].logGroupName' --output text
}

our_runtimes() {
  aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
    --query "agentRuntimes[?agentRuntimeName=='$RUNTIME_NAME'].[agentRuntimeId,status]" --output text
}

# IAM is global and the regional tagging index may not list roles; check by name.
ROLE_PREFIX="$(printf '%s' "$PROJECT" | cut -c1-20)-"
our_roles() {
  aws iam list-roles --query "Roles[?starts_with(RoleName, '$ROLE_PREFIX')].RoleName" --output text
}

# --- report -----------------------------------------------------------------
# Prints removed / in progress and sets PENDING (count) and BILLABLE (count of
# pending things that are not free network plumbing).
report() {
  local state made held groups rt roles tagged a free
  state="$(in_state)"; made="$(created)"
  held="$(agentcore_enis)"; groups="$(runtime_log_groups)"
  rt="$(our_runtimes)"; roles="$(our_roles)"
  PENDING=0 BILLABLE=0

  echo "Removed:"
  if [ -n "$made" ]; then
    for a in $made; do grep -qxF "$a" <<<"$state" || echo "  ok    $a"; done
  else
    echo "  (no manifest from up.sh; listing only what is left)"
  fi
  [ -n "$rt" ] || echo "  ok    AgentCore runtime $RUNTIME_NAME"
  [ -n "$groups" ] || echo "  ok    runtime log groups /aws/bedrock-agentcore/runtimes/${RUNTIME_ID:-<id>}-*"
  [ -n "$roles" ] || echo "  ok    IAM roles $ROLE_PREFIX*"

  echo "In progress:"
  for a in $state; do
    PENDING=$((PENDING + 1))
    case "$a" in
      aws_vpc.*|aws_subnet.*|aws_security_group.*|aws_route_table*|aws_internet_gateway.*) free="no cost" ;;
      *) free="BILLABLE"; BILLABLE=$((BILLABLE + 1)) ;;
    esac
    echo "  wip   $a  ($free)"
  done
  if [ -n "$held" ]; then
    echo "  wip   AgentCore network interfaces $held (no cost)"
    echo "        AWS releases these on its own, up to 8+ hours after the runtime is"
    echo "        deleted; they are what keeps the VPC, subnets and security group."
  fi
  if [ -n "$rt" ]; then
    PENDING=$((PENDING + 1)) BILLABLE=$((BILLABLE + 1))
    echo "  wip   AgentCore runtime $rt"
  fi
  for a in $groups; do
    PENDING=$((PENDING + 1))
    echo "  wip   log group $a (storage only)"
  done
  for a in $roles; do
    PENDING=$((PENDING + 1))
    echo "  wip   IAM role $a (no cost)"
  done
  [ "$PENDING" -gt 0 ] || echo "  nothing"

  # Informational only: the tagging index keeps deleted resources (and INACTIVE
  # ECS clusters / task definitions) for a while, so it does not decide "done".
  tagged="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters "Key=Project,Values=$PROJECT" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text)"
  if [ -n "$tagged" ] && [ "$PENDING" = "0" ]; then
    echo "Note: the tag index still lists these; it lags deletions (ECS keeps INACTIVE"
    echo "      records), and state above is empty, so they are already deleted:"
    printf '        %s\n' $tagged
  fi
  echo "Left on purpose: AWSServiceRoleForBedrockAgentCoreNetwork, the account-wide"
  echo "      service-linked role shared by every AgentCore VPC agent (free)."
}

# One destroy pass. Output goes to the log; returns tofu's status.
destroy_pass() {
  echo "== $(date -u +%FT%TZ) tofu destroy" >>"$LOG"
  tofu destroy -input=false -auto-approve -no-color -var "agent_image_tag=unused" >>"$LOG" 2>&1
}

delete_log_groups() {
  local g
  for g in $(runtime_log_groups); do
    if aws logs delete-log-group --region "$REGION" --log-group-name "$g"; then
      echo "  deleted $g"
    else
      echo "  could not delete $g (re-run later)" >&2
    fi
  done
}

# --- check ------------------------------------------------------------------
if [ "$MODE" = check ]; then
  echo "Teardown status for '$PROJECT' in $REGION, $(date -u +%FT%TZ):"
  report
  if [ "$PENDING" = "0" ]; then
    echo "Finished. Nothing left."
    exit 0
  fi
  if [ -n "$(in_state)" ] && [ -z "$(agentcore_enis)" ]; then
    echo "Nothing blocks the rest any more: run ./scripts/down.sh --yes to finish."
  fi
  exit 3
fi

# --- down -------------------------------------------------------------------
echo "About to destroy everything for project '$PROJECT' in $REGION:"
echo "  $(in_state | wc -l | tr -d ' ') resources in state, AgentCore runtime '${RUNTIME_ID:-none}'"
echo "  This deletes asz's stored conversations (EFS) and the agent images (ECR)."
if [ "$YES" != 1 ]; then
  read -r -p "Type the project name to confirm: " answer
  [ "$answer" = "$PROJECT" ] || { echo "Aborted."; exit 1; }
fi

echo "== deletion requested (tofu output: $LOG) =="
start=$(date +%s)
pass=1
while :; do
  if [ -z "$(in_state)" ] || destroy_pass; then
    echo "  pass $pass: tofu state is empty"
  else
    echo "  pass $pass: $(in_state | wc -l | tr -d ' ') resources still in state"
  fi
  # The runtime is gone after the first pass; its log groups can go now.
  delete_log_groups
  [ -n "$(in_state)" ] || break
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt "$WAIT" ] || break
  held="$(agentcore_enis)"
  if [ -n "$held" ]; then
    echo "  waiting on AgentCore network interfaces $held ($((elapsed / 60))/$((WAIT / 60)) min)"
  fi
  sleep 60
  pass=$((pass + 1))
done

echo "== status =="
report
if [ "$PENDING" = "0" ]; then
  rm -f "$MANIFEST"
  echo "Down. Nothing left."
  exit 0
fi

echo
echo "Shutdown is requested but not finished after $((WAIT / 60)) min."
if [ "$BILLABLE" = "0" ]; then
  echo "Everything that bills is gone; what is left above costs nothing."
else
  echo "WARNING: $BILLABLE item(s) above may still bill; see $LOG." >&2
fi
echo "  Re-check any time:   ./scripts/down.sh check"
echo "  Finish it later:     ./scripts/down.sh --yes   (safe to re-run)"
echo "Manifest kept at $MANIFEST so the check can tell removed from in progress."
exit 3
