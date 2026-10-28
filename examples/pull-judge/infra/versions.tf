terraform {
  required_version = ">= 1.6.0" # OpenTofu >= 1.6 or Terraform >= 1.6

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.x carries aws_bedrockagentcore_agent_runtime, so the agent itself is
      # in OpenTofu state and `tofu destroy` removes it with everything else.
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Every resource carries these tags; scripts/down.sh queries them afterwards
  # to prove nothing is left.
  default_tags {
    tags = local.tags
  }
}
