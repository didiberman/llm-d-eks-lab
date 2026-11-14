# Open WebUI — a chat front end for whatever model this tier serves.
#
# Talks to the llm-d router over the in-cluster OpenAI-compatible API, so
# every chat goes through the EPP exactly like `make load` traffic does.
#
# Deliberately light:
#   - no Ollama, Pipelines, Redis or Tika subcharts
#   - no persistence: this cluster has no EBS CSI driver, and chats/settings
#     of a lab that is reaped nightly are not worth a volume. A pod restart
#     resets Open WebUI to a clean state.
#   - auth off (WEBUI_AUTH=False). The NLB only admits allowed_cidrs — the
#     same boundary as the model endpoint itself, which has no auth either.
#     If allowed_cidrs is opened up, turn auth back on.
#
# Lives in 20-inference so it is deployed by CI with the model and torn down
# with it by `make down` and the nightly reaper.

locals {
  webui_release = "open-webui"
}

resource "helm_release" "webui" {
  count = var.enable_webui ? 1 : 0

  name       = local.webui_release
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://helm.openwebui.com/"
  chart      = "open-webui"
  version    = var.webui_chart_version

  wait    = true
  timeout = 600

  values = [yamlencode({
    ollama    = { enabled = false }
    pipelines = { enabled = false }
    tika      = { enabled = false }
    websocket = { enabled = false, redis = { enabled = false } }

    persistence = { enabled = false }

    # In-cluster router service — port 80 is the Envoy sidecar in front of
    # the EPP (see manifests/router/values.yaml.tftpl).
    openaiBaseApiUrl = "http://${var.release_name}-epp.${var.namespace}.svc.cluster.local/v1"
    # vLLM ignores the key, but Open WebUI refuses an empty one.
    openaiApiKey = "unused"

    extraEnvVars = [
      { name = "WEBUI_AUTH", value = "False" },
      { name = "ENABLE_OLLAMA_API", value = "False" },
      { name = "DEFAULT_MODELS", value = var.model },
      # Skip downloading the local embedding model at startup; RAG over
      # uploaded documents is not what this lab is for.
      { name = "RAG_EMBEDDING_MODEL_AUTO_UPDATE", value = "False" },
      { name = "ENABLE_RAG_WEB_SEARCH", value = "False" },
    ]

    nodeSelector = { "llm-d-eks-lab/role" = "system" }

    resources = {
      requests = { cpu = "100m", memory = "512Mi" }
      limits   = { memory = "2Gi" }
    }
  })]

  depends_on = [helm_release.router]
}

# Same pattern as the router's public endpoint: the built-in EKS controller
# understands `nlb`, and source ranges become node security-group rules.
resource "kubernetes_service" "webui_public" {
  count = var.enable_webui ? 1 : 0

  metadata {
    name      = "${local.webui_release}-public"
    namespace = kubernetes_namespace.this.metadata[0].name

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      "app.kubernetes.io/instance"  = local.webui_release
      "app.kubernetes.io/component" = "open-webui"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    load_balancer_source_ranges = var.allowed_cidrs
  }

  depends_on = [helm_release.webui]
}
