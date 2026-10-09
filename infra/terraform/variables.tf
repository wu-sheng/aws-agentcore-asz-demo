# ---------------------------------------------------------------------------
# ALL deploy-specific values live here. Nothing is hardcoded in main.tf.
# Copy terraform.tfvars.example -> terraform.tfvars and fill these in.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into (must offer Bedrock AgentCore Runtime)."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile used by the provider. null = the SDK's default chain."
  type        = string
  default     = null
}

variable "project_name" {
  description = "Prefix for resource names, and the Project tag every resource carries."
  type        = string
  default     = "aws-agentcore-asz-demo"
}

variable "tags" {
  description = "Extra tags applied to all resources."
  type        = map(string)
  default     = {}
}

# --- networking -------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (NAT gateway and the UI load balancer)."
  type        = list(string)
  default     = ["10.42.1.0/24", "10.42.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (asz task, EFS, ingest load balancer, AgentCore agent ENIs)."
  type        = list(string)
  default     = ["10.42.11.0/24", "10.42.12.0/24"]
}

variable "availability_zone_ids" {
  description = <<-EOT
    AZ ids for the subnets, one per subnet CIDR (e.g. ["use1-az1", "use1-az2"]).
    AgentCore VPC mode only places agents in some AZs of a region; if apply
    fails on the agent runtime's subnets, set this to supported AZ ids.
    Empty = the region's first available AZs.
  EOT
  type        = list(string)
  default     = []
}

variable "asz_ui_cidrs" {
  description = "CIDRs allowed to open the asz UI (public load balancer, port 8787). Use your own IP, e.g. [\"203.0.113.7/32\"]."
  type        = list(string)
}

# --- asz --------------------------------------------------------------------
variable "asz_image" {
  description = "asz container image (multi-arch, distroless, non-root uid 65532)."
  type        = string
  default     = "ghcr.io/apache/skywalking-ai-sessionizer:latest"
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

variable "asz_collect_interval" {
  description = "How often asz assembles what the receiver landed (asz duration)."
  type        = string
  default     = "30s"
}

# --- agent ------------------------------------------------------------------
variable "agent_ecr_repo_name" {
  description = "ECR repository for the LangGraph agent image (AgentCore pulls from here)."
  type        = string
  default     = "aws-agentcore-asz-demo-agent"
}

variable "agent_image_tag" {
  description = <<-EOT
    Tag of the agent image already pushed to the ECR repo. Empty = do not create
    the AgentCore runtime yet. scripts/up.sh applies once without it (to create
    the repo), pushes the image, then applies again with the tag.
  EOT
  type        = string
  default     = ""
}

variable "bedrock_model_id" {
  description = "Bedrock model (or inference profile) id for the agent. Empty = the scripted stand-in model."
  type        = string
  default     = ""
}
