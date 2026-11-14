# T3 — the real target. ~$1.85/hr per replica.
#
# g6e.xlarge is an L40S with 44GB usable VRAM. Qwen3.6-27B-FP8 is 28.7GB of
# weights, leaving ~13GB of KV cache — the largest model in this family that
# still holds enough concurrent sequences for queue depth to be a meaningful
# autoscaling signal.
#
# max_replicas = 2 is a QUOTA ceiling, not a preference: 8 vCPU of granted
# G/VT spot divided by 4 vCPU per g6e.xlarge. Raising it without raising quota
# produces pods that stay Pending forever.
#
# NOTE: g6e.xlarge has only 32GB of host RAM against 28.7GB of weights. vLLM
# streams safetensors shards so it should not OOM, but this is the first thing
# to suspect if weight loading misbehaves. g6e.2xlarge (64GB host RAM) is the
# fix, at the cost of using the entire quota on a single replica.
tier    = "gpu"
use_gpu = true

model       = "Qwen/Qwen3.6-27B-FP8"
model_image = "docker.io/vllm/vllm-openai:v0.30.0"

instance_types = ["g6e.xlarge"]
disk_size_gb   = 200

min_replicas = 1
max_replicas = 2
