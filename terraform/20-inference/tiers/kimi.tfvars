# Kimi-Dev-72B — the biggest Kimi that fits this account's quota. ~$8.29/hr.
#
# moonshotai/Kimi-Dev-72B is a 72.7B coding model (Qwen2.5-72B base, plain
# Qwen2ForCausalLM, MIT, ungated). It ships BF16 only: 145GB on disk, ~135GiB
# in VRAM. No single GPU on AWS's G family holds that, so it runs tensor-
# parallel across the two 96GB RTX PRO 6000 cards of a g7e.12xlarge:
#
#   2 x 96GiB x 0.92 = ~177GiB usable - 135GiB weights = ~40GiB of KV cache
#
# ONE REPLICA ONLY, and that is a quota fact rather than a preference: the node
# is 48 vCPU and the on-demand G/VT quota is 64, so a second can never launch.
# There is no scale-out to watch on this tier — use `make gpu` for that.
#
# On-demand, not spot: the spot G/VT quota is 8 vCPU, a sixth of this node.
#
# Fallback if g7e misbehaves (new GPU generation, unproven with this AMI and
# vLLM image): g6e.12xlarge, 4x L40S, also 48 vCPU, $10.49/hr. Set
# instance_types = ["g6e.12xlarge"], gpu_count = 4, --tensor-parallel-size 4.
tier    = "kimi"
use_gpu = true

model       = "moonshotai/Kimi-Dev-72B"
model_image = "docker.io/vllm/vllm-openai:v0.30.0"

instance_types = ["g7e.12xlarge"]
capacity_types = ["on-demand"]
gpu_vcpu_limit = 48
gpu_count      = 2

# 145GB of weights plus the ~10GB image plus HF cache overhead.
disk_size_gb         = 400
disk_throughput_mbps = 1000
disk_iops            = 8000

model_server_args = [
  "--port", "8000",
  "--tensor-parallel-size", "2",
  # The model supports 131072, but every token of context is KV cache taken
  # from concurrent requests. 32k is plenty for a coding lab.
  "--max-model-len", "32768",
  "--gpu-memory-utilization", "0.92",
  # Open WebUI (and most agent frameworks) send tool_choice "auto"; vLLM
  # rejects that with a 400 unless tool calling is enabled. Kimi-Dev-72B is a
  # Qwen2.5 fine-tune, which emits Hermes-style <tool_call> blocks.
  "--enable-auto-tool-choice",
  "--tool-call-parser", "hermes",
  "--disable-access-log-for-endpoints", "/health,/metrics,/v1/models",
  "--shutdown-timeout", "45",
]

# The node has 48 vCPU and 512GB of RAM and hosts nothing else. The generous
# memory limit is for page cache while 145GB of safetensors stream to the GPUs.
model_server_resources = {
  cpu_request    = "16"
  memory_request = "64Gi"
  memory_limit   = "256Gi"
}

# Tensor-parallel workers talk over shared memory.
shm_size = "16Gi"

# 145GB to download and load: 240 x 10s = 40 minutes before the pod is killed.
startup_probe_failure_threshold = 240

min_replicas = 1
max_replicas = 1
