terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 so every pipeline run shares state and stays idempotent.
  # Create this bucket once before `terraform init` (see README.md).
  # In CI these values are supplied with -backend-config=... flags.
  backend "s3" {
    bucket = "CHANGE-ME-mattermost-tfstate"
    key    = "mattermost/terraform.tfstate"
    region = "ap-south-1"
    # Native S3 state locking (Terraform >= 1.10) — no DynamoDB table needed.
    use_lockfile = true
  }
}
