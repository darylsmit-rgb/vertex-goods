provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = merge(
      {
        ManagedBy = "terraform"
        Purpose   = "eks-workload-pod-identity"
      },
      var.tags
    )
  }
}

data "aws_eks_cluster" "workload" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "workload" {
  name = var.cluster_name
}

data "aws_eks_node_groups" "workload" {
  cluster_name = var.cluster_name
}

data "aws_eks_node_group" "workload" {
  for_each = data.aws_eks_node_groups.workload.names

  cluster_name    = var.cluster_name
  node_group_name = each.value
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.workload.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.workload.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.workload.token
}
