variable "region" {
  description = "AWS region. Must match 10-cluster."
  type        = string
  default     = "us-west-2"

  nullable = false
}

variable "project" {
  description = "Project slug, used for the Project cost-allocation tag."
  type        = string
  default     = "llm-d-eks-lab"

  nullable = false
}

variable "state_bucket" {
  description = "S3 bucket holding remote state, from the 00-bootstrap output. The Makefile passes this."
  type        = string
}

variable "namespace" {
  description = "Namespace for the router and model servers."
  type        = string
  default     = "llm-d"

  nullable = false
}

variable "release_name" {
  description = "Helm release name for the router. Determines derived names the ScaledObject depends on: EPP service is <release>-epp and the InferencePool is <release>. Changing it without updating autoscaling.tf breaks the metric queries silently."
  type        = string
  default     = "llm-d"

  nullable = false
}

# ---------------------------------------------------------------------------
# Tier selection. Pass one of the files in tiers/ via -var-file; the Makefile
# does this. The three tiers differ only in the variables below.
# ---------------------------------------------------------------------------

variable "tier" {
  description = "Which tier this is. Only affects naming and outputs; the real differences are the variables below."
  type        = string
  default     = "gpu"

  validation {
    condition     = contains(["sim", "small", "gpu", "kimi"], var.tier)
    error_message = "tier must be one of: sim, small, gpu, kimi."
  }

  nullable = false
}

variable "capacity_types" {
  description = "Karpenter capacity types for model server nodes. G/VT quota in us-west-2 is 8 vCPU spot and 64 vCPU on-demand, so anything larger than two xlarge nodes must be on-demand."
  type        = list(string)
  default     = ["spot"]

  validation {
    condition     = length(var.capacity_types) > 0 && alltrue([for c in var.capacity_types : contains(["spot", "on-demand"], c)])
    error_message = "capacity_types must be a non-empty list of: spot, on-demand."
  }

  nullable = false
}

variable "gpu_vcpu_limit" {
  description = "vCPU ceiling on the GPU NodePool. Keep at or below the G/VT quota for the chosen capacity type, so a breach shows up as a Pending pod rather than opaque EC2 launch failures."
  type        = number
  default     = 8

  nullable = false
}

variable "gpu_count" {
  description = "GPUs per model server pod. Above 1, also pass --tensor-parallel-size with the same value in model_server_args."
  type        = number
  default     = 1

  validation {
    condition     = var.gpu_count >= 1 && var.gpu_count <= 8
    error_message = "gpu_count must be between 1 and 8."
  }

  nullable = false
}

variable "startup_probe_failure_threshold" {
  description = "Startup probe attempts at 10s each before the pod is killed. Must cover weight download plus load: 60 (10 min) suits a ~30GB model, a ~145GB one needs far longer."
  type        = number
  default     = 60

  nullable = false
}

variable "shm_size" {
  description = "Size of the in-memory /dev/shm volume. Counts against the pod memory limit."
  type        = string
  default     = "4Gi"

  nullable = false
}

variable "use_gpu" {
  description = "Whether model server pods request nvidia.com/gpu. False for the simulator tier, which needs no accelerator at all."
  type        = bool
  default     = true

  nullable = false
}

variable "instance_types" {
  description = "Instance types Karpenter may provision for model servers. Keep every entry's VRAM adequate for the model: a NodePool mixing 44GB L40S and 22GB L4 will happily schedule a 28GB model onto the L4 and OOM."
  type        = list(string)
  default     = ["g6e.xlarge"]

  nullable = false
}

variable "model" {
  description = "HuggingFace model id to serve. Must match the model_name label on EPP metrics, which is what the KEDA queries filter on."
  type        = string
  default     = "Qwen/Qwen3.6-27B-FP8"

  nullable = false
}

variable "model_image" {
  description = "Container image for the model server. vLLM 0.30 is what llm-d v1.0.0 pins; the simulator stands in for it on the sim tier."
  type        = string
  default     = "docker.io/vllm/vllm-openai:v0.30.0"

  nullable = false
}

variable "model_server_args" {
  description = "Args for the model server container."
  type        = list(string)

  default = [
    "--port", "8000",
    "--max-model-len", "16384",
    # 0.92 leaves a little VRAM for the CUDA context; pushing to 0.95+ on a
    # 44GB card with 28.7GB of weights tends to OOM during graph capture.
    "--gpu-memory-utilization", "0.92",
    # Qwen3.5+ models are multimodal and the vision tower costs VRAM we need
    # for KV cache. Disable image/video inputs for text benchmarking; raise
    # these if you actually want multimodal.
    "--limit-mm-per-prompt", "image=0,video=0",
    "--disable-access-log-for-endpoints", "/health,/metrics,/v1/models",
    # Drain in-flight requests on SIGTERM so a spot reclaim does not drop
    # responses mid-stream. Must stay under terminationGracePeriodSeconds.
    "--shutdown-timeout", "45",
  ]

  nullable = false
}

variable "model_server_resources" {
  description = "CPU/memory requests for the model server. Sized well under the node so the kubelet and DaemonSets fit; GPU count is handled separately via use_gpu."
  type = object({
    cpu_request    = string
    memory_request = string
    memory_limit   = string
  })

  default = {
    cpu_request    = "2"
    memory_request = "16Gi"
    memory_limit   = "24Gi"
  }

  nullable = false
}

variable "disk_size_gb" {
  description = "Node root volume. Must hold the ~10GB vLLM image plus the model weights plus HF cache overhead; 200GB is comfortable for a 28GB model and costs ~$0.02/hr."
  type        = number
  default     = 200

  nullable = false
}

variable "disk_throughput_mbps" {
  description = "gp3 root volume throughput in MB/s. Null keeps the gp3 baseline of 125, which takes ~20 minutes just to write 145GB of weights; 1000 costs ~$0.05/hr extra."
  type        = number
  default     = null
}

variable "disk_iops" {
  description = "gp3 root volume IOPS. Null keeps the gp3 baseline of 3000."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Autoscaling
# ---------------------------------------------------------------------------

variable "min_replicas" {
  description = "Minimum model server replicas. 1 keeps a warm replica so requests do not pay a 2-5 minute cold start; 0 drops idle GPU cost to zero at the price of that cold start on the next request."
  type        = number
  default     = 1

  nullable = false
}

variable "max_replicas" {
  description = "Maximum model server replicas. CAPPED BY GPU QUOTA: with 8 vCPU of G/VT spot and 4 vCPU per g6e.xlarge, 2 is the ceiling. Raising this without raising quota means pods that stay Pending forever."
  type        = number
  default     = 2

  validation {
    condition     = var.max_replicas >= 1 && var.max_replicas <= 16
    error_message = "max_replicas must be between 1 and 16."
  }

  nullable = false
}

variable "queue_depth_target" {
  description = "Per-replica target for llm_d_epp_flow_control_queue_size. 1 means 'scale up as soon as a request is waiting' — aggressive, which is what you want for a demo you can actually observe."
  type        = number
  default     = 1

  nullable = false
}

variable "running_requests_target" {
  description = "Per-replica target for llm_d_epp_request_running, raced against queue depth by the HPA (larger desired count wins). Upstream uses 16."
  type        = number
  default     = 16

  nullable = false
}

variable "scale_stabilization_seconds" {
  description = "HPA stabilization window, both directions. Must be near the model cold-start time or the autoscaler reacts to demand from replicas that are still loading weights, overshoots, then flaps when they go Ready."
  type        = number
  default     = 300

  nullable = false
}

# ---------------------------------------------------------------------------
# Access and secrets
# ---------------------------------------------------------------------------

variable "hf_token" {
  description = "HuggingFace token. The llm-d charts expect the llm-d-hf-token secret to exist even for ungated models. Set via TF_VAR_hf_token; never commit it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "create_public_endpoint" {
  description = "Expose the router through an internet-facing NLB. The endpoint is UNAUTHENTICATED — restrict allowed_cidrs. Set false to reach it only via kubectl port-forward."
  type        = bool
  default     = true

  nullable = false
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the public endpoint. Defaults to open, which puts an unauthenticated LLM on the internet; narrow this to your own /32."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  nullable = false
}

variable "install_nvidia_device_plugin" {
  description = "Install the NVIDIA device plugin DaemonSet. The EKS-optimized AL2023 NVIDIA AMI ships the driver and container toolkit but not the device plugin, so without this GPU nodes never advertise nvidia.com/gpu and the model server stays Pending on a billing node."
  type        = bool
  default     = true

  nullable = false
}

variable "nvidia_device_plugin_version" {
  description = "nvidia-device-plugin Helm chart version, used only when install_nvidia_device_plugin is true."
  type        = string
  default     = "0.20.1"

  nullable = false
}

variable "router_chart_version" {
  description = "llm-d router chart version. Keep aligned with the llm-d release pinned in 10-cluster."
  type        = string
  default     = "v1.0.0"

  nullable = false
}

variable "enable_webui" {
  description = "Deploy Open WebUI as a chat front end for the served model, exposed on its own NLB restricted to allowed_cidrs."
  type        = bool
  default     = true

  nullable = false
}

variable "webui_chart_version" {
  description = "open-webui Helm chart version (https://helm.openwebui.com/)."
  type        = string
  default     = "18.3.0"

  nullable = false
}
