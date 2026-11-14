# EKS control plane plus a deliberately tiny system node group.
#
# The system node group exists so Karpenter, Istio and KEDA have somewhere to
# run that is not a GPU. Without it you get a deadlock: Karpenter is what
# provisions nodes, so it cannot be the thing waiting for a node.
#
# No EBS CSI driver on purpose — model weights land on the Karpenter-managed
# node root volume (sized per tier in the EC2NodeClass), so there is no
# PersistentVolume in the picture and no reason to carry the addon.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.project
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  # Public endpoint: this cluster is driven from a laptop on a changing IP, and
  # there is no bastion. Narrow api_allowed_cidrs for anything long-lived.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs
  endpoint_private_access      = true

  # Off: with deploys running in CI, "whoever ran terraform" would flip
  # between the CI role and a human, replacing the admin entry each time.
  # Admins are listed explicitly in access_entries below instead.
  enable_cluster_creator_admin_permissions = false
  enable_irsa                              = true

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    system = {
      instance_types = var.system_instance_types

      # Spot for the system group too. If a reclaim takes a platform
      # controller the replacement reschedules; that is a useful thing to
      # watch happen rather than a problem to avoid.
      capacity_type = "SPOT"

      min_size     = 1
      max_size     = 4
      desired_size = var.system_node_desired_size

      # Nodes are in public subnets and need a public IP to reach the IGW,
      # since there is no NAT.
      associate_public_ip_address = true

      labels = {
        "llm-d-eks-lab/role" = "system"
      }

      tags = merge(local.tags, { NodeGroup = "system" })
    }
  }

  # Who may administer the cluster. Keys are part of the Terraform address:
  #   cluster_creator — the human admin. Keyed to match the module's own
  #                     creator entry so a cluster first built locally adopts
  #                     it in place instead of replacing it.
  #   deploy          — the GitHub Actions deploy role (applies this layer
  #                     and verifies Argo CD syncs).
  access_entries = { for k, v in {
    cluster_creator = var.admin_principal_arn
    deploy          = var.deploy_role_arn
    } : k => {
    principal_arn = v

    policy_associations = {
      admin = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = {
          type = "cluster"
        }
      }
    }
  } if v != null }

  # Karpenter discovers which security group to attach to the nodes it creates.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.project
  }

  tags = local.tags
}
