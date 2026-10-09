output "asz_ui_url" {
  description = "asz web UI. Reachable from asz_ui_cidrs only."
  value       = "http://${aws_lb.ui.dns_name}:${local.asz_ui_port}"
}

output "asz_ingest_endpoint" {
  description = "LangSmith receiver (LANGSMITH_ENDPOINT). Internal: reachable from the agent's security group only."
  value       = "http://${aws_lb.ingest.dns_name}:${local.asz_ingest_port}"
}

output "agent_ecr_repository_url" {
  description = "Push the linux/arm64 agent image here."
  value       = aws_ecr_repository.agent.repository_url
}

output "agent_runtime_arn" {
  description = "AgentCore runtime ARN to invoke. Empty until agent_image_tag is set."
  value       = local.agent_enabled ? aws_bedrockagentcore_agent_runtime.agent[0].agent_runtime_arn : ""
}

output "agent_runtime_id" {
  description = "AgentCore runtime id; its log groups are /aws/bedrock-agentcore/runtimes/<id>-*."
  value       = local.agent_enabled ? aws_bedrockagentcore_agent_runtime.agent[0].agent_runtime_id : ""
}

output "asz_log_group" {
  value = aws_cloudwatch_log_group.asz.name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "project_tag" {
  description = "Every resource carries Project=<this>; scripts/down.sh checks none remain."
  value       = var.project_name
}

output "asz_ingest_token" {
  description = "Receiver token (the agent's LANGSMITH_API_KEY)."
  value       = random_password.asz_ingest_token.result
  sensitive   = true
}
