# GitOps hand-off: Terraform installs Argo CD and exactly one Application —
# the root of an app-of-apps in gitops/root. From then on the inference layer
# (llm-d router, model server, NodePool, ScaledObject, Open WebUI, NVIDIA
# device plugin) is reconciled by Argo CD from git, and `deploy/config.yaml`
# is the switch.
#
# The boundary: anything that needs AWS identities or values that must not be
# committed stays here. The root Application's valuesObject is how those
# values reach the charts:
#   - karpenter.nodeRole  the IAM role Karpenter's EC2NodeClass assigns
#   - allowedCidrs        the operator IP allowlist (a GitHub secret)
# and the HF token becomes a Kubernetes Secret below, never a git file.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version

  wait    = true
  timeout = 900

  # Same file local/argocd-up.sh installs on kind.
  values = [file("${path.module}/../../gitops/bootstrap/argocd-values.yaml")]

  depends_on = [module.eks, helm_release.karpenter]
}

resource "kubernetes_namespace" "llm_d" {
  metadata {
    name = "llm-d"
    labels = {
      "llm-d-eks-lab/managed" = "true"
    }
  }

  depends_on = [module.eks]
}

# The model server mounts HF_TOKEN unconditionally; an empty value is fine for
# ungated models.
resource "kubernetes_secret" "hf_token" {
  metadata {
    name      = "llm-d-hf-token"
    namespace = kubernetes_namespace.llm_d.metadata[0].name
  }

  data = {
    HF_TOKEN = var.hf_token
  }

  type = "Opaque"
}

resource "kubectl_manifest" "root_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      # Deleting the root app cascades through every child app and what they
      # deployed — the destroy workflow relies on this to remove NLBs and
      # Karpenter nodes before the cluster goes.
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = "gitops/root"
        helm = {
          # The tier comes from git; everything below comes from Terraform.
          valueFiles = ["../../deploy/config.yaml"]
          valuesObject = {
            repoURL        = var.gitops_repo_url
            targetRevision = var.gitops_revision
            environment    = "eks"
            project        = var.project
            karpenter = {
              nodeRole     = module.karpenter.node_iam_role_name
              discoveryTag = var.project
            }
            allowedCidrs = var.allowed_cidrs
          }
        }
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    helm_release.keda,
    helm_release.prometheus,
    null_resource.gaie_crds,
    kubernetes_secret.hf_token,
  ]
}
