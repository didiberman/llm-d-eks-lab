# The model server Deployment: vLLM (or the GPU-free simulator) serving the
# model behind llm-d's router.
#
# Two contracts with the router chart, both verified by rendering the chart
# (`helm template`) rather than assumed. Break either and the router silently
# has no backends:
#
#   1. Pods MUST carry the label `llm-d.ai/inference-pool: <release>`. That is
#      the selector on the chart's headless `<release>-epp-model-servers`
#      Service and on the InferencePool.
#   2. Pods MUST serve on container port 8000. That port is hardcoded in the
#      chart's model-servers Service.

resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace

    labels = {
      "llm-d-eks-lab/managed" = "true"
    }
  }
}

# The llm-d charts expect this secret to exist even for ungated models — the
# modelserver mounts HF_TOKEN unconditionally.
resource "kubernetes_secret" "hf_token" {
  metadata {
    name      = "llm-d-hf-token"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  data = {
    HF_TOKEN = var.hf_token
  }

  type = "Opaque"
}

locals {
  decode_name = "${var.release_name}-vllm-decode"

  model_server_labels = {
    # Contract 1 — the router's pool selector.
    "llm-d.ai/inference-pool" = var.release_name
    "llm-d.ai/role"           = "decode"
    "llm-d-eks-lab/tier"      = var.tier
  }
}

resource "kubernetes_deployment" "decode" {
  metadata {
    name      = local.decode_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.model_server_labels
  }

  spec {
    # Replica count is owned by KEDA's HPA after creation, so Terraform must
    # not fight it on every apply — see the lifecycle block below.
    replicas = var.min_replicas

    # Kubernetes' default is 600s, after which the rollout is marked failed and
    # Terraform errors — even though the pod is healthy and still loading.
    # Must outlast the startup probe window plus image pull and scheduling.
    progress_deadline_seconds = var.startup_probe_failure_threshold * 10 + 600

    selector {
      match_labels = {
        "llm-d.ai/inference-pool" = var.release_name
        "llm-d.ai/role"           = "decode"
      }
    }

    strategy {
      type = "RollingUpdate"

      rolling_update {
        # One GPU per replica and a hard quota ceiling: surging would ask for a
        # node that cannot exist, so updates replace in place instead.
        max_surge       = "0"
        max_unavailable = "1"
      }
    }

    template {
      metadata {
        labels = local.model_server_labels
      }

      spec {
        # Must exceed vLLM's --shutdown-timeout (45s) so in-flight requests
        # drain before SIGKILL. Matters on spot: a reclaim gives 2 minutes.
        termination_grace_period_seconds = 60

        node_selector = {
          "llm-d-eks-lab/role" = "model-server"
          "llm-d-eks-lab/tier" = var.tier
        }

        dynamic "toleration" {
          for_each = var.use_gpu ? [1] : []

          content {
            key      = "nvidia.com/gpu"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        }

        container {
          name  = "modelserver"
          image = var.model_image

          # The simulator takes a different CLI, so only vLLM gets `vllm serve`.
          command = var.use_gpu ? ["vllm", "serve"] : null
          args    = var.use_gpu ? concat([var.model], var.model_server_args) : ["--model", var.model, "--port", "8000"]

          # Contract 2 — the chart's model-servers Service targets 8000.
          port {
            name           = "http"
            container_port = 8000
            protocol       = "TCP"
          }

          env {
            name = "HF_TOKEN"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.hf_token.metadata[0].name
                key  = "HF_TOKEN"
              }
            }
          }

          # Keep the HF cache on the node's big root volume rather than the
          # container filesystem.
          env {
            name  = "HF_HOME"
            value = "/cache/huggingface"
          }

          resources {
            requests = merge(
              {
                cpu    = var.model_server_resources.cpu_request
                memory = var.model_server_resources.memory_request
              },
              var.use_gpu ? { "nvidia.com/gpu" = tostring(var.gpu_count) } : {}
            )

            limits = merge(
              { memory = var.model_server_resources.memory_limit },
              var.use_gpu ? { "nvidia.com/gpu" = tostring(var.gpu_count) } : {}
            )
          }

          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          # Weight download plus load plus CUDA graph capture is minutes, not
          # seconds. failure_threshold x period_seconds must exceed the worst
          # cold start or Kubernetes kills the pod mid-load and loops forever.
          # Default 60 x 10s = 10 minutes of headroom; large models raise it
          # per tier via startup_probe_failure_threshold.
          startup_probe {
            http_get {
              path = "/health"
              port = "http"
            }

            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = var.startup_probe_failure_threshold
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }

            period_seconds    = 15
            timeout_seconds   = 5
            failure_threshold = 4
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }

            period_seconds    = 5
            timeout_seconds   = 3
            failure_threshold = 3
          }
        }

        volume {
          name = "cache"

          empty_dir {}
        }

        volume {
          name = "shm"

          empty_dir {
            medium     = "Memory"
            size_limit = var.shm_size
          }
        }
      }
    }
  }

  # Without a NodePool the pod can never schedule, and Terraform would then
  # sit in the rollout wait until the timeout. Ordering after it makes a
  # NodePool error fail the apply immediately instead.
  depends_on = [kubectl_manifest.nodepool]

  # KEDA's HPA owns replicas once the ScaledObject exists. Without this,
  # every `terraform apply` would reset the cluster back to min_replicas and
  # fight the autoscaler.
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }

  timeouts {
    # Terraform waits for the rollout, so this must outlast the startup probe
    # window of the slowest tier (kimi: up to 40 minutes).
    create = "50m"
    update = "50m"
  }
}
