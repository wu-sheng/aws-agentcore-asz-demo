#!/usr/bin/env bash
# Check the local toolchain and set up the agent's Python venv.
# Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== Checking local toolchain =="

check() {
  if command -v "$1" >/dev/null 2>&1; then
    printf "  [ok]   %-12s %s\n" "$1" "$($2 2>&1 | head -1)"
  else
    printf "  [MISS] %-12s %s\n" "$1" "$3"
    MISSING=1
  fi
}

MISSING=0
check python3 "python3 --version"      "install Python 3.10+"
check docker  "docker --version"       "install Docker Desktop (needs buildx for ARM64)"
check tofu    "tofu version"           "brew install opentofu   (or use terraform)"
check aws     "aws --version"          "brew install awscli      (Tier-2 only)"
check gh      "gh --version"           "brew install gh          (repo ops)"

if [ "${MISSING:-0}" = "1" ]; then
  echo
  echo "Some tools are missing (see [MISS] above). Tier-1 needs python3 + docker only."
fi

echo
echo "== Creating agent venv =="
python3 -m venv agent/.venv
# shellcheck disable=SC1091
source agent/.venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -e "agent[deploy,dev]"
echo "  venv ready at agent/.venv (activate: source agent/.venv/bin/activate)"

echo
echo "Next:"
echo "  Tier-1:  ./scripts/run-asz-local.sh   then  (cd agent && python app.py --local)"
echo "  Tier-2:  cd infra/terraform && cp terraform.tfvars.example terraform.tfvars && tofu init && tofu apply"
