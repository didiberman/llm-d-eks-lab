# Karpenter: the piece that makes GPU cost collapse to zero when idle.
#
# The controller lives here; the NodePool and EC2NodeClass that describe GPU
# nodes are part of the inference layer Argo CD manages (gitops/apps/
# model-server), so tier: none removes the ability to create GPUs without
# touching the cluster.
#
# `consolidationPolicy: WhenEmptyOrUnderutilized` (set on that NodePool) is
# what reclaims a GPU node roughly a minute after the last pod leaves it.

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name
  region       = var.region

  # The SQS queue + EventBridge rules for spot interruption notices are created
  # by default. Without them Karpenter learns about a reclaim when the node
  # vanishes, instead of getting the two-minute warning and draining
  # gracefully. On an all-spot GPU setup that is the difference between a
  # graceful handoff and dropped requests.
  #
  # Auth is EKS Pod Identity (create_pod_identity_association defaults true),
  # not IRSA — so the Helm chart's service account needs no role annotation.
  # Module defaults for namespace/service_account are kube-system/karpenter,
  # which is exactly what the release below creates.

  # Let the nodes Karpenter creates pull from ECR and register with the cluster.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  wait = true

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    # Keep the controller on the system node group; it must never land on a
    # node it is itself responsible for reclaiming.
    nodeSelector = {
      "llm-d-eks-lab/role" = "system"
    }
    controller = {
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]

  depends_on = [module.eks]
}
