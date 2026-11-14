# Network, built around one decision: NO NAT GATEWAY.
#
# Three NAT Gateways cost $0.135/hr idle plus $0.045/GB processed. An LLM
# workload pulls a ~10GB vLLM image and 100GB+ of weights on every cold pod
# start, so the data-processing charge alone can exceed the GPU bill. Nodes
# therefore live in PUBLIC subnets with public IPs and egress straight out the
# IGW, where ingress is free.
#
# The trade: nodes are internet-reachable, so their security group is the only
# thing between the kubelet and the world. Acceptable for a disposable practice
# cluster; not a pattern to copy into production, where you would pay for NAT
# or use VPC endpoints for everything.
#
# Deliberately NO ECR/STS interface endpoints either: those bill $0.01/hr per
# AZ per endpoint ($0.18/hr for two across three AZs) and buy nothing when the
# nodes already have a direct route out. Only the S3 *gateway* endpoint is
# created, because gateway endpoints are free.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Layer     = "10-cluster"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.project
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]

  # The entire point. Left explicit rather than relying on the module default,
  # because silently acquiring a NAT Gateway is this project's main cost risk.
  enable_nat_gateway     = false
  single_nat_gateway     = false
  one_nat_gateway_per_az = false

  create_igw              = true
  map_public_ip_on_launch = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Lets the AWS load balancer machinery and Karpenter discover where to place
  # things. Karpenter matches on karpenter.sh/discovery.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
    "karpenter.sh/discovery" = var.project
  }

  tags = local.tags
}

# Free (gateway endpoints have no hourly or data charge) and keeps S3 traffic
# off the public path.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.public_route_table_ids

  tags = merge(local.tags, { Name = "${var.project}-s3" })
}
