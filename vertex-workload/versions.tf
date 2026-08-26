terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.58, < 7.0"
    }

    spectrocloud = {
      source  = "spectrocloud/spectrocloud"
      version = ">= 0.29.9, < 0.30.0"
    }
  }
}
