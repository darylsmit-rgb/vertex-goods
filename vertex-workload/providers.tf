provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = merge(
      {
        ManagedBy = "terraform"
        Purpose   = "palette-vertex-pod-identity-workload"
      },
      var.aws_tags
    )
  }
}

# Tenant scope owns the cloud account registered under Tenant Settings.
provider "spectrocloud" {
  alias = "tenant"
  host  = var.spectrocloud_host

  feature_preview = {
    "immutable-clusterprofiles" = true
  }
}

# Project scope owns the profile version and workload cluster.
provider "spectrocloud" {
  alias        = "project"
  host         = var.spectrocloud_host
  project_name = var.spectrocloud_project_name

  feature_preview = {
    "immutable-clusterprofiles" = true
  }
}

data "aws_partition" "current" {}

data "spectrocloud_cluster_profile" "source" {
  provider = spectrocloud.project

  name    = var.source_profile_name
  version = var.source_profile_version
  context = "project"
}
