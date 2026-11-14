# Karpenter EC2NodeClass + NodePool for model server capacity.
#
# This is the file that makes idle GPU cost zero. It lives in 20-inference, not
# 10-cluster, so `make down` removes the cluster's ability to create GPU nodes
# without tearing down the cluster itself.

locals {
  nodepool_name = "${var.project}-${var.tier}"

  # Karpenter needs the GPU taint so that only pods explicitly tolerating it
  # land on expensive hardware. Without it, any unschedulable pod in the
  # cluster could trigger a $1.85/hr node.
  gpu_taints = var.use_gpu ? [{
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NoSchedule"
  }] : []
}

resource "kubectl_manifest" "ec2nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = local.nodepool_name
    }
    spec = {
      # `al2023@latest` resolves to the EKS-optimized accelerated AL2023 AMI
      # for GPU instance types, which bundles the NVIDIA driver, the container
      # runtime hook and the device plugin. That is why
      # install_nvidia_device_plugin defaults to false.
      amiSelectorTerms = [{ alias = "al2023@latest" }]

      role = local.node_role

      subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = local.discovery } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = local.discovery } }]

      # NO NAT GATEWAY in this VPC, so nodes sit in public subnets and need a
      # public IP to reach the internet at all. Without this they cannot pull
      # the vLLM image or the model weights and will sit NotReady.
      associatePublicIPAddress = true

      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        rootVolume = true
        ebs = merge(
          {
            volumeSize          = "${var.disk_size_gb}Gi"
            volumeType          = "gp3"
            deleteOnTermination = true
            encrypted           = true
          },
          var.disk_throughput_mbps == null ? {} : { throughput = var.disk_throughput_mbps },
          var.disk_iops == null ? {} : { iops = var.disk_iops },
        )
      }]

      # Reclaim the node promptly once empty. This is half of why idle cost
      # collapses; the NodePool's consolidation policy is the other half.
      metadataOptions = {
        httpTokens              = "required"
        httpPutResponseHopLimit = 2
      }

      # karpenter.sh/* tags are reserved — the API server rejects the whole
      # EC2NodeClass if one is set here. Karpenter adds karpenter.sh/nodepool
      # to instances itself.
      tags = merge(local.tags, {
        Name = local.nodepool_name
      })
    }
  })
}

resource "kubectl_manifest" "nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = local.nodepool_name
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "llm-d-eks-lab/role" = "model-server"
            "llm-d-eks-lab/tier" = var.tier
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = local.nodepool_name
          }

          taints = local.gpu_taints

          requirements = concat([
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = var.instance_types
            },
            {
              # Set per tier. Quota differs sharply by capacity type (8 vCPU
              # spot, 64 vCPU on-demand), so permitting a type the tier's
              # shape cannot fit just produces launch failures that look
              # like capacity problems.
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.capacity_types
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            ], var.use_gpu ? [] : [
            # Non-GPU tiers: let Karpenter avoid the tiny burstable sizes whose
            # CPU credits run out mid-benchmark.
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"]
            },
          ])

          # A reclaimed spot node is replaced rather than leaving the
          # Deployment short. 30s gives vLLM time to drain in-flight requests
          # (its --shutdown-timeout is 45s, so the grace period on the pod is
          # what actually governs).
          terminationGracePeriod = "2m"

          expireAfter = "24h"
        }
      }

      disruption = {
        # The mechanism that makes this project cheap: once a node has no
        # model server pods on it, Karpenter terminates it within about a
        # minute instead of leaving a $1.85/hr GPU idling.
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }

      limits = {
        # Hard ceiling matching the granted G/VT quota for this tier's
        # capacity type. Karpenter refuses to exceed this even if KEDA asks
        # for more replicas, which turns a quota breach into a visible Pending
        # pod rather than a stream of opaque EC2 launch failures.
        cpu = var.use_gpu ? var.gpu_vcpu_limit : 16
      }

      # Higher weight than any default pool, so model servers land here.
      weight = 100
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass]
}

# Advertises nvidia.com/gpu on GPU nodes. The AL2023 NVIDIA AMI has the driver
# but not this DaemonSet. Pinned to model-server nodes so it never lands on
# the system node group.
resource "helm_release" "nvidia_device_plugin" {
  count = var.use_gpu && var.install_nvidia_device_plugin ? 1 : 0

  name             = "nvidia-device-plugin"
  namespace        = "nvidia-device-plugin"
  create_namespace = true
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = var.nvidia_device_plugin_version

  values = [yamlencode({
    nodeSelector = { "llm-d-eks-lab/role" = "model-server" }
    tolerations = [{
      key      = "nvidia.com/gpu"
      operator = "Exists"
      effect   = "NoSchedule"
    }]
  })]
}
