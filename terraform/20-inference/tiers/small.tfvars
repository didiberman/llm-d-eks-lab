# T2 — a real GPU, a small model. ~$0.43/hr per replica.
#
# g6.xlarge is an L4 with 22GB usable VRAM, so the model must stay small:
# Qwen3.5-4B is 8.7GB of weights, leaving ~11GB of KV cache. Good for
# iterating on config against real CUDA without paying L40S rates.
tier    = "gpu"
use_gpu = true

model       = "Qwen/Qwen3.5-4B"
model_image = "docker.io/vllm/vllm-openai:v0.30.0"

instance_types = ["g6.xlarge"]
disk_size_gb   = 100

model_server_args = [
  "--port", "8000",
  "--max-model-len", "16384",
  "--gpu-memory-utilization", "0.90",
  "--limit-mm-per-prompt", "image=0,video=0",
  "--disable-access-log-for-endpoints", "/health,/metrics,/v1/models",
  "--shutdown-timeout", "45",
]

model_server_resources = {
  cpu_request    = "2"
  memory_request = "8Gi"
  memory_limit   = "12Gi"
}

min_replicas = 1
max_replicas = 2
