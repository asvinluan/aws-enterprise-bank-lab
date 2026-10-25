terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.90" # pinned: an unpinned provider upgrade is an unreviewed change
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Local state is fine for a one-person lab. For anything shared, copy
  # backend.tf.example to backend.tf (S3 + locking + KMS) and run terraform init -migrate-state.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge({
      Project   = "meridian-bank-lab"
      ManagedBy = "terraform"
    }, var.tags)
  }
}
