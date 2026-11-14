# GitHub Actions OIDC: the provider and the deploy role CI assumes.
#
# Lives in 00-bootstrap, not 10-cluster, because CI needs the role before it
# can build anything, and the destroy workflow uses it to tear 10-cluster down.
# This layer is the only one `make destroy` leaves standing.
#
# Set github_repo to enable. Left null by default so a fresh clone does not
# create IAM principals nobody asked for.

data "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo == null ? 0 : (var.create_github_oidc_provider ? 0 : 1)

  url = "https://token.actions.githubusercontent.com"
}

# Accounts often already have this provider from another project; creating a
# second one fails. Flip create_github_oidc_provider to false to reuse.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo == null ? 0 : (var.create_github_oidc_provider ? 1 : 0)

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

locals {
  oidc_arn = var.github_repo == null ? null : (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

# ---------------------------------------------------------------------------
# Deploy role — what the deploy workflow assumes to apply 10-cluster and
# verify Argo CD. Every deploy goes through CI; nothing is applied from a laptop
# except this bootstrap layer, which has to exist before CI can authenticate.
#
# Trust is pinned to main: only workflows running on main may assume it, so a
# pull request from a branch cannot deploy or read state.
#
# Repos with immutable OIDC subjects enabled send
# `repo:<owner>@<owner-id>/<name>@<repo-id>:...` instead of
# `repo:<owner>/<name>:...`; the plain form then never matches and every
# assume fails with "Not authorized". Check which one a repo sends with:
#   gh api repos/<owner>/<name>/actions/oidc/customization/sub
#
# AdministratorAccess because 10-cluster creates a VPC, an EKS cluster, IAM
# roles, KMS keys, SQS queues and EventBridge rules — enumerating that surface
# by hand is brittle and buys little on a single-purpose lab account. The trust
# condition is the real boundary.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "github_deploy_assume" {
  count = var.github_repo == null ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${coalesce(var.github_oidc_sub_prefix, "repo:${var.github_repo}")}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  count = var.github_repo == null ? 0 : 1

  name                 = "${var.project}-github-deploy"
  description          = "Assumed by the GitHub Actions deploy workflow on main to apply 10-cluster and 20-inference"
  assume_role_policy   = data.aws_iam_policy_document.github_deploy_assume[0].json
  max_session_duration = 7200

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "github_deploy_admin" {
  count = var.github_repo == null ? 0 : 1

  role       = aws_iam_role.github_deploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
