provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_eks_cluster" "management" {
  name = var.management_cluster_name
}

data "aws_eks_cluster_auth" "management" {
  name = var.management_cluster_name
}

data "aws_eks_node_groups" "management" {
  count = var.discover_management_node_roles ? 1 : 0

  cluster_name = var.management_cluster_name
}

data "aws_eks_node_group" "management" {
  for_each = var.discover_management_node_roles ? data.aws_eks_node_groups.management[0].names : toset([])

  cluster_name    = var.management_cluster_name
  node_group_name = each.value
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.management.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.management.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.management.token
}
