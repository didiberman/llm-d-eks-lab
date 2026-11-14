variable "region" {
  description = "AWS region. Keep in sync with the 00-bootstrap state bucket region."
  type        = string
  default     = "us-west-2"

  nullable = false
}

variable "project" {
  description = "Project slug used as the cluster name prefix and the Project cost-allocation tag."
  type        = string
  default     = "llm-d-eks-lab"

  nullable = false
}

variable "kubernetes_version" {
  description = "EKS control plane version. 1.37 is the current AWS default (standard support to 2027-12-01)."
  type        = string
  default     = "1.37"

  nullable = false
}

variable "vpc_cidr" {
  description = "VPC CIDR. /16 is far more than needed but leaves room for the pod IPs the VPC CNI hands out."
  type        = string
  default     = "10.0.0.0/16"

  nullable = false
}

variable "az_count" {
  description = "Number of availability zones. Three gives Karpenter room to find spot capacity; one AZ makes spot interruptions far more disruptive."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "EKS requires subnets in at least 2 AZs; more than 4 is pointless here."
  }

  nullable = false
}

variable "system_instance_types" {
  description = "Instance types for the system node group that hosts Karpenter, Istio and KEDA. Deliberately tiny and non-GPU."
  type        = list(string)
  default     = ["t3.xlarge", "t3a.xlarge", "m6i.xlarge"]

  nullable = false
}

variable "system_node_desired_size" {
  description = "System node count. Two spreads the platform controllers across AZs; one is cheaper but a single spot reclaim takes the cluster's brain with it."
  type        = number
  default     = 2

  nullable = false
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Defaults to open because a locked-down default makes a practice cluster unusable from a changing IP; narrow it to your own /32 for anything you leave running."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  nullable = false
}

variable "budget_limit_usd" {
  description = "Monthly budget in USD that triggers the SNS email alert. The nightly reaper is the real protection; this is the backstop."
  type        = number
  default     = 50

  nullable = false
}

variable "budget_alert_email" {
  description = "Email for budget alerts. Leave null to skip creating the budget and SNS topic entirely."
  type        = string
  default     = null
}

# Pinned to the llm-d v1.0.0 tested matrix, NOT to latest upstream. Istio's
# newest is 1.31.x, but llm-d v1.0 is tested against 1.29.4 — the gateway is on
# the request path for every token, so track what they test.
variable "gateway_api_version" {
  description = "Gateway API CRD version. llm-d v1.0.0 pins v1.6.2."
  type        = string
  default     = "v1.6.2"

  nullable = false
}

variable "gaie_version" {
  description = "Gateway API Inference Extension CRD version. llm-d v1.0.0 pins v1.6.2."
  type        = string
  default     = "v1.6.2"

  nullable = false
}

variable "istio_version" {
  description = "Istio version. llm-d v1.0.0 is tested against 1.29.4; kgateway was removed in v1.0."
  type        = string
  default     = "1.29.4"

  nullable = false
}

variable "prometheus_chart_version" {
  description = "kube-prometheus-stack chart version. Required: KEDA scales on EPP metrics scraped by Prometheus, and the llm-d router chart emits a ServiceMonitor, so the Prometheus Operator CRDs must exist."
  type        = string
  default     = "92.16.0"

  nullable = false
}

variable "enable_istio" {
  description = "Install Istio. NOT needed for llm-d standalone router mode, which proxies requests itself via an Envoy sidecar and is exposed by a plain LoadBalancer Service. Only turn this on for the Gateway API dataplane path."
  type        = bool
  default     = false

  nullable = false
}

variable "keda_version" {
  description = "KEDA Helm chart version. KEDA drives replica count from llm-d EPP queue depth."
  type        = string
  default     = "2.21.0"

  nullable = false
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version."
  type        = string
  default     = "1.15.1"

  nullable = false
}

variable "reaper_role_arn" {
  description = "IAM role ARN from the 00-bootstrap github_reaper_role_arn output. Granted cluster-admin via an EKS access entry so the nightly reaper can actually delete workloads. Null to skip."
  type        = string
  default     = null
}

variable "admin_principal_arn" {
  description = "IAM principal (user or role) granted cluster-admin for kubectl from a workstation. Null to grant no human access."
  type        = string
  default     = null
}

variable "deploy_role_arn" {
  description = "IAM role ARN from the 00-bootstrap github_deploy_role_arn output. Granted cluster-admin so the deploy workflow can manage Helm releases and the inference layer."
  type        = string
  default     = null
}
