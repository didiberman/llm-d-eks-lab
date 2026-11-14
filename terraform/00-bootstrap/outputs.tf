output "state_bucket" {
  description = "S3 bucket holding remote state. Feed this to the 10-cluster and 20-inference backend blocks."
  value       = aws_s3_bucket.this.id
}

output "region" {
  description = "Region the state bucket lives in."
  value       = var.region
}

output "backend_config" {
  description = "Paste-ready backend block for the downstream layers."

  value = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.this.id}"
        key          = "<layer>/terraform.tfstate"
        region       = "${var.region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}

output "github_reaper_role_arn" {
  description = "ARN to put in the AWS_REAPER_ROLE_ARN GitHub secret. Null unless github_repo is set."
  value       = try(aws_iam_role.github_reaper[0].arn, null)
}

output "github_deploy_role_arn" {
  description = "ARN to put in the AWS_DEPLOY_ROLE_ARN GitHub secret. Null unless github_repo is set."
  value       = try(aws_iam_role.github_deploy[0].arn, null)
}
