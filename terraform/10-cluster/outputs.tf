output "cluster_name" {
  description = "EKS cluster name. 20-inference reads this from remote state."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the cluster, for downstream providers."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN, for service accounts created in 20-inference."
  value       = module.eks.oidc_provider_arn
}

output "region" {
  description = "Region the cluster lives in."
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnets. The Karpenter EC2NodeClass in 20-inference places GPU nodes here."
  value       = module.vpc.public_subnets
}

output "karpenter_node_iam_role_name" {
  description = "IAM role the EC2NodeClass in 20-inference assigns to GPU nodes."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_discovery_tag" {
  description = "Value of the karpenter.sh/discovery tag on subnets and the node security group."
  value       = var.project
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "nat_gateway_count" {
  description = "Always 0. Asserted as an output so a regression is visible in the plan diff rather than only on the bill."
  value       = 0
}
