terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.82"
    }
  }

  # Local state — matches the us-east-1 root module convention.
  # If you later want remote state, create an S3 bucket and uncomment a
  # `backend "s3"` block; running `terraform init -migrate-state` will move
  # the existing local state into it without redeploying anything.
}

# -----------------------------------------------------------------------------
# Primary provider — us-west-2 (the GPU estate).
# -----------------------------------------------------------------------------
provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      Project     = "observability-rca"
      Environment = "demo"
      Sprint      = "Sprint-4"
      ManagedBy   = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Aliased provider — us-east-1.
# AWS Billing metrics (AWS/Billing namespace) are published ONLY in us-east-1,
# regardless of where the spending happens. The CloudWatch billing alarm +
# its SNS topic in gateway.tf reference this alias.
# -----------------------------------------------------------------------------
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "observability-rca"
      Environment = "demo"
      Sprint      = "Sprint-4"
      ManagedBy   = "terraform"
    }
  }
}
