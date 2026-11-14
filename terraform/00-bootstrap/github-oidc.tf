# GitHub Actions OIDC role for the nightly reaper.
#
# Lives in 00-bootstrap, not 10-cluster, because the reaper's whole job is to
# destroy 10/20 — it cannot depend on the thing it deletes. This layer is also
# the only one `make nuke` leaves standing.
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

data "aws_iam_policy_document" "github_assume" {
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

    # Scoped to this repository only. Without this condition ANY GitHub repo
    # in the world could assume the role.
    #
    # Repos with immutable OIDC subjects enabled send
    # `repo:<owner>@<owner-id>/<name>@<repo-id>:...` instead of
    # `repo:<owner>/<name>:...`; the plain form then never matches and every
    # assume fails with "Not authorized". Check which one a repo sends with:
    #   gh api repos/<owner>/<name>/actions/oidc/customization/sub
    #
    # Pinned to main: the reaper runs on schedule and workflow_dispatch, both
    # of which execute on the default branch. A wildcard would let a workflow
    # on any branch assume the role — unacceptable once the repo is public.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${coalesce(var.github_oidc_sub_prefix, "repo:${var.github_repo}")}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_reaper" {
  count = var.github_repo == null ? 0 : 1

  name               = "${var.project}-github-reaper"
  description        = "Assumed by GitHub Actions to destroy the inference layer nightly"
  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json

  tags = var.tags
}

# Permissions needed to run `terraform destroy` on 20-inference:
#   - read/write the remote state in S3
#   - describe the cluster and mint a token to reach its API
#   - delete the NLB that the LoadBalancer Service created
#   - terminate the instances Karpenter launched, in case Karpenter itself is
#     already gone when the reaper runs
data "aws_iam_policy_document" "github_reaper" {
  count = var.github_repo == null ? 0 : 1

  statement {
    sid    = "RemoteState"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
  }

  statement {
    sid    = "ClusterAccess"
    effect = "Allow"

    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "TeardownCompute"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:TerminateInstances",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteTargetGroup",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_reaper" {
  count = var.github_repo == null ? 0 : 1

  name   = "reaper"
  role   = aws_iam_role.github_reaper[0].id
  policy = data.aws_iam_policy_document.github_reaper[0].json
}

# ---------------------------------------------------------------------------
# Deploy role — what the deploy workflow assumes to apply 10-cluster and
# 20-inference. Every deploy goes through CI; nothing is applied from a laptop
# except this bootstrap layer, which has to exist before CI can authenticate.
#
# Trust is narrower than the reaper's: only workflows running on main may
# assume it, so a pull request from a branch cannot deploy or read state.
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
