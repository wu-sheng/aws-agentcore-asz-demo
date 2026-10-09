output "asz_endpoint" {
  description = "URL the agent's langsmith client should point at (LANGCHAIN_ENDPOINT). The AgentCore microVM must be able to reach this."
  value       = "http://${aws_lb.asz.dns_name}:${var.asz_port}"
}

output "asz_ui_url" {
  description = "asz web UI (same ALB)."
  value       = "http://${aws_lb.asz.dns_name}:${var.asz_port}"
}

output "agent_ecr_repository_url" {
  description = "Push the ARM64 agent image here; AgentCore Runtime pulls from this repo."
  value       = aws_ecr_repository.agent.repository_url
}

output "vpc_id" {
  description = "VPC id — AgentCore egress to asz must terminate in or route to this VPC when the ALB is internal."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}
