terraform {
  required_version = "~> 1.13"

  backend "s3" {
    key          = "20-inference/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    # alekc/kubectl rather than hashicorp/kubernetes' kubernetes_manifest:
    # kubernetes_manifest requires the CRD to already exist at *plan* time,
    # which makes a from-scratch apply impossible for EC2NodeClass, NodePool
    # and ScaledObject. This provider applies raw YAML without that constraint.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}

# 10-cluster owns the cluster; this layer only consumes its outputs. Keeping
# them in separate states is what lets `make down` destroy the GPUs without
# touching a 16-minute cluster rebuild.
data "terraform_remote_state" "cluster" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "10-cluster/terraform.tfstate"
    region = var.region
  }
}

locals {
  cluster_name = data.terraform_remote_state.cluster.outputs.cluster_name
  cluster_host = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca   = data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data
  subnet_ids   = data.terraform_remote_state.cluster.outputs.public_subnet_ids
  node_role    = data.terraform_remote_state.cluster.outputs.karpenter_node_iam_role_name
  discovery    = data.terraform_remote_state.cluster.outputs.karpenter_discovery_tag

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Layer     = "20-inference"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

provider "kubernetes" {
  host                   = local.cluster_host
  cluster_ca_certificate = base64decode(local.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_host
    cluster_ca_certificate = base64decode(local.cluster_ca)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = local.cluster_host
  cluster_ca_certificate = base64decode(local.cluster_ca)
  load_config_file       = false
  apply_retry_count      = 3

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}
