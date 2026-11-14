# KEDA ScaledObject: the heart of the project.
#
# Scales the model server Deployment on EPP *demand* signals, not utilisation.
# A GPU running inference reads ~100% busy whether it is comfortably keeping up
# or badly backlogged, so utilisation cannot distinguish the two. Queue depth
# can.
#
# Two triggers, raced by the generated HPA (larger desired count wins):
#
#   llm_d_epp_flow_control_queue_size  unmet demand        target 1  per replica
#   llm_d_epp_request_running          active concurrency  target 16 per replica
#
# The queue metric only exists if the EPP runs with `featureGates:
# [flowControl]` — set in manifests/router/values.yaml.tftpl. Without it this
# query returns empty and nothing ever scales, with no error anywhere.
#
# Prometheus address is the one 10-cluster installs. KEDA's prometheus scaler
# ignores a TriggerAuthentication CA unless authModes is also set, so plain
# in-cluster HTTP is used deliberately rather than TLS (upstream keda-epp guide
# makes the same choice and cites KEDA PR #2571).

locals {
  prometheus_address = "http://llmd-kube-prometheus-stack-prometheus.llm-d-monitoring.svc.cluster.local:9090"
  epp_service        = "${var.release_name}-epp"

  # Label selectors on the EPP metrics. model_name must match var.model exactly
  # or both queries return nothing.
  metric_selector = "namespace=\"${var.namespace}\",service=\"${local.epp_service}\",model_name=\"${var.model}\""
}

resource "kubectl_manifest" "scaledobject" {
  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "${var.release_name}-keda-epp"
      namespace = var.namespace
    }
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = local.decode_name
      }

      pollingInterval = 15

      # Applies to scale-to-zero only; the HPA behavior below governs ordinary
      # scale-down while minReplicaCount >= 1.
      cooldownPeriod = 300

      minReplicaCount = var.min_replicas
      maxReplicaCount = var.max_replicas

      advanced = {
        horizontalPodAutoscalerConfig = {
          name = "keda-hpa-${var.release_name}"

          # Startup-time mitigation. A model server takes minutes to load
          # weights and become Ready; while it starts it serves nothing, so
          # demand stays elevated (scale-up overshoot) and then collapses once
          # Ready (scale-down flap). Both windows damp that, and should be
          # sized near the real cold-start time.
          behavior = {
            scaleUp = {
              stabilizationWindowSeconds = var.scale_stabilization_seconds
              policies = [{
                type          = "Percent"
                value         = 100
                periodSeconds = 15
              }]
            }
            scaleDown = {
              stabilizationWindowSeconds = var.scale_stabilization_seconds
              policies = [{
                type          = "Percent"
                value         = 100
                periodSeconds = 15
              }]
            }
          }
        }
      }

      triggers = [
        {
          type       = "prometheus"
          name       = "epp-queue-size"
          metricType = "AverageValue"
          metadata = {
            serverAddress = local.prometheus_address
            query         = "sum(llm_d_epp_flow_control_queue_size{${local.metric_selector}})"
            threshold     = tostring(var.queue_depth_target)
          }
        },
        {
          type       = "prometheus"
          name       = "epp-running-requests"
          metricType = "AverageValue"
          metadata = {
            serverAddress = local.prometheus_address
            query         = "sum(llm_d_epp_request_running{${local.metric_selector}})"
            threshold     = tostring(var.running_requests_target)
          }
        },
      ]
    }
  })

  depends_on = [
    helm_release.router,
    kubernetes_deployment.decode,
  ]
}
