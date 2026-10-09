# ---------------------------------------------------------------------------
# ALL deploy-specific values live here. Nothing is hardcoded in main.tf.
# Copy terraform.tfvars.example -> terraform.tfvars and fill these in.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into (must support Bedrock AgentCore)."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile name used by the provider."
  type        = string
  default     = "default"
}

variable "project_name" {
  description = "Prefix for all resource names/tags."
  type        = string
  default     = "aws-agentcore-asz-demo"
}

# --- asz collector image ----------------------------------------------------
variable "asz_image" {
  description = "Official multi-arch skywalking-ai-sessionizer image reference (registry/name:tag)."
  type        = string
  # Replace with the actual published coordinates once confirmed.
  default = "apache/skywalking-ai-sessionizer:latest"
}

variable "asz_port" {
  description = "Port asz server listens on (container binds 0.0.0.0:asz_port)."
  type        = number
  default     = 8787
}

variable "asz_cpu" {
  description = "Fargate task CPU units for asz."
  type        = number
  default     = 512
}

variable "asz_memory" {
  description = "Fargate task memory (MiB) for asz."
  type        = number
  default     = 1024
}

# --- networking -------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (ALB lives here)."
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (asz task + EFS live here)."
  type        = list(string)
  default     = ["10.42.11.0/24", "10.42.12.0/24"]
}

variable "asz_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the asz ALB on asz_port. The AgentCore microVM must be
    able to reach this. For a quick PoC with a public ALB, narrow this to your own
    IP plus whatever egress range AgentCore uses. For a VPC-private design, keep
    the ALB internal and this list to the VPC CIDR.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"] # OVERRIDE: do not leave open in anything but a throwaway PoC
}

variable "asz_alb_internal" {
  description = "If true, the asz ALB is internal (VPC-private). If false, internet-facing. Depends on AgentCore egress model."
  type        = bool
  default     = false
}

# --- agent / ECR ------------------------------------------------------------
variable "agent_ecr_repo_name" {
  description = "ECR repository name for the LangGraph agent image (AgentCore pulls from here)."
  type        = string
  default     = "langgraph-agentcore-asz-agent"
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}
