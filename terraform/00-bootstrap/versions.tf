terraform {
  required_version = "~> 1.13"

  # State lives in the bucket this layer creates — it was previously committed
  # to git, which leaks the account ID and IAM layout in a public repo.
  # Bucket and region come from -backend-config (see `make bootstrap`).
  #
  # Brand-new account: the bucket does not exist yet, so the first apply must
  # run with this block commented out; then restore it and run
  # `terraform init -migrate-state` to move the local state into S3.
  backend "s3" {
    key          = "00-bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}
