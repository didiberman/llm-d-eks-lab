variable "region" {
  description = "AWS region hosting the remote state bucket. Must match the region the cluster is built in."
  type        = string
  default     = "us-west-2"

  nullable = false
}

variable "project" {
  description = "Project slug used as a name prefix and as the cost-allocation tag value."
  type        = string
  default     = "llm-d-eks-lab"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project))
    error_message = "Project must be 3-32 chars of lowercase letters, digits, or hyphens."
  }

  nullable = false
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state. Leave null to derive one from the project and account ID."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource. The Project tag is what makes `make cost` able to attribute spend."
  type        = map(string)

  default = {
    Project   = "llm-d-eks-lab"
    ManagedBy = "terraform"
  }

  nullable = false
}

variable "github_repo" {
  description = "GitHub repo in owner/name form, enabling the OIDC role the nightly reaper assumes. Leave null to skip creating any IAM principal."
  type        = string
  default     = null
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if this AWS account already has one from another project — a second one fails to create."
  type        = bool
  default     = true

  nullable = false
}

variable "github_oidc_sub_prefix" {
  description = "Subject prefix GitHub puts in this repo's OIDC tokens, without the trailing colon. Leave null for the classic `repo:<owner>/<name>`. Set it to the sub_claim_prefix from `gh api repos/<owner>/<name>/actions/oidc/customization/sub` when the repo uses immutable subjects."
  type        = string
  default     = null
}
