output "tier" {
  description = "Which tier is deployed."
  value       = var.tier
}

output "model" {
  description = "Model being served."
  value       = var.model
}

output "endpoint" {
  description = "Public NLB hostname, once AWS has provisioned it. Empty when create_public_endpoint is false."
  value = try(
    kubernetes_service.router_public[0].status[0].load_balancer[0].ingress[0].hostname,
    ""
  )
}

output "test_command" {
  description = "Paste-ready request against the deployed model."

  value = var.create_public_endpoint ? format(
    "curl -s http://%s/v1/completions -H 'Content-Type: application/json' -d '{\"model\":\"%s\",\"prompt\":\"The capital of France is\",\"max_tokens\":32}' | jq",
    try(kubernetes_service.router_public[0].status[0].load_balancer[0].ingress[0].hostname, "<pending>"),
    var.model
  ) : "kubectl -n ${var.namespace} port-forward svc/${var.release_name}-epp 8080:80"
}

output "watch_command" {
  description = "Watch autoscaling and node provisioning happen."

  value = join(" ; ", [
    "kubectl -n ${var.namespace} get scaledobject,hpa,pods",
    "kubectl get nodes -l llm-d-eks-lab/role=model-server",
  ])
}

output "replica_bounds" {
  description = "Min/max replicas. Max is capped by GPU quota, not preference."
  value       = "${var.min_replicas}..${var.max_replicas}"
}

output "gpu_vcpu_ceiling" {
  description = "vCPU ceiling enforced on the Karpenter NodePool, matching the granted G/VT quota. Pods beyond this stay Pending rather than producing opaque EC2 launch failures."
  value       = var.use_gpu ? var.gpu_vcpu_limit : 16
}

output "webui_url" {
  description = "Open WebUI address. Empty when enable_webui is false."
  value = try(
    "http://${kubernetes_service.webui_public[0].status[0].load_balancer[0].ingress[0].hostname}",
    ""
  )
}
