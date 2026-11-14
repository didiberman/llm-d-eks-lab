# T1 — llm-d-inference-sim, no GPU at all.
#
# The simulator speaks the vLLM OpenAI API and emits genuine vLLM Prometheus
# metrics, so the router, EPP, KEDA and Karpenter all behave exactly as they
# would with a real model — for ~$0.03/hr of CPU instead of $1.85/hr of GPU.
# Use this to debug the autoscaling path; it is the cheapest honest test there is.
tier    = "sim"
use_gpu = false

model       = "Qwen/Qwen3.5-4B"
model_image = "ghcr.io/llm-d/llm-d-inference-sim:v1.0.0"

instance_types = ["c7i.large", "m7i.large", "c6i.large"]
disk_size_gb   = 40

model_server_resources = {
  cpu_request    = "500m"
  memory_request = "1Gi"
  memory_limit   = "2Gi"
}

min_replicas = 1
max_replicas = 4
