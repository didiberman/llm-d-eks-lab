# The llm-d router in standalone mode: EPP (endpoint picker) plus an Envoy
# sidecar, fronting the model server pods.
#
# Standalone mode means the router proxies requests itself, so no Gateway API
# dataplane (Istio) is required — which is why enable_istio defaults to false
# in 10-cluster. The chart creates all services as ClusterIP, so the public
# endpoint is a LoadBalancer Service added below.

resource "helm_release" "router" {
  name      = var.release_name
  namespace = kubernetes_namespace.this.metadata[0].name

  repository = "oci://ghcr.io/llm-d/charts"
  chart      = "llm-d-router-standalone"
  version    = var.router_chart_version

  wait    = true
  timeout = 600

  values = [
    templatefile("${path.module}/../../manifests/router/values.yaml.tftpl", {
      inference_pool = var.release_name
    })
  ]

  depends_on = [
    kubernetes_secret.hf_token,
    kubectl_manifest.nodepool,
  ]
}

# Public endpoint. The chart only makes ClusterIP services, so this is a
# separate LoadBalancer selecting the router pods.
#
# Selector and port verified by rendering the chart:
#   selector  llm-d-router-gateway: <release>-epp
#   port 80 -> targetPort 8081 (the Envoy sidecar's listener)
#
# This cluster does NOT run the AWS Load Balancer Controller, so the Service
# is reconciled by the cloud provider built into the EKS control plane. That
# controller only understands `aws-load-balancer-type: nlb` (instance targets,
# internet-facing by default). The newer `external` / `nlb-target-type: ip`
# annotations tell it to stand aside for a controller that is not installed —
# the Service then never gets an address and the apply hangs.
resource "kubernetes_service" "router_public" {
  count = var.create_public_endpoint ? 1 : 0

  metadata {
    name      = "${var.release_name}-public"
    namespace = kubernetes_namespace.this.metadata[0].name

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "llm-d-router-gateway" = "${var.release_name}-epp"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8081
      protocol    = "TCP"
    }

    # THE ENDPOINT IS UNAUTHENTICATED. Defaults to 0.0.0.0/0, which puts an
    # open LLM on the internet; set allowed_cidrs to your own /32.
    load_balancer_source_ranges = var.allowed_cidrs
  }

  depends_on = [helm_release.router]
}
