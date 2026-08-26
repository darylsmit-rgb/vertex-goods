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

provider "kubernetes" {
  host                   = data.aws_eks_cluster.management.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.management.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.management.token
}

