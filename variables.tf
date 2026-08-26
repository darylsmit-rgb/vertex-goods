variable "aws_region" {
  description = "AWS region containing the existing EKS management cluster."
  type        = string
  nullable    = false
}

variable "aws_profile" {
  description = "Optional AWS CLI profile used by the AWS provider."
  type        = string
  default     = null
}

variable "management_cluster_name" {
  description = "Name of the existing EKS cluster that hosts Palette VerteX."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.management_cluster_name) > 0
    error_message = "management_cluster_name cannot be empty."
  }
}

variable "network_mode" {
  description = "Use existing for an existing VPC or create to let Palette create VPC resources."
  type        = string
  default     = "existing"

  validation {
    condition     = contains(["existing", "create"], var.network_mode)
    error_message = "network_mode must be either existing or create."
  }
}

variable "name_suffix" {
  description = "Suffix applied to the customer-managed IAM policy names."
  type        = string
  default     = "navy"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,48}$", var.name_suffix))
    error_message = "name_suffix must be 1-48 valid IAM-name characters."
  }
}

variable "palette_role_name" {
  description = "IAM role used by Palette to provision and manage EKS workload clusters."
  type        = string
  default     = "SpectroCloudPaletteRole"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.palette_role_name))
    error_message = "palette_role_name must be a valid IAM role name."
  }
}

variable "hubble_role_name" {
  description = "IAM role used by the Palette Hubble service for AWS account validation."
  type        = string
  default     = "SpectroCloudHubbleRole"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.hubble_role_name))
    error_message = "hubble_role_name must be a valid IAM role name."
  }
}

variable "identity_role_name" {
  description = "IAM role used by the Palette Identity service."
  type        = string
  default     = "SpectroCloudIdentityRole"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.identity_role_name))
    error_message = "identity_role_name must be a valid IAM role name."
  }
}

variable "manage_cloudformation" {
  description = "Allow Palette to manage the CAPA CloudFormation stack automatically."
  type        = bool
  default     = true
}

variable "manage_pod_identity_agent" {
  description = "Manage the EKS Pod Identity Agent as an AWS-managed EKS add-on. Set false when a Palette cluster profile owns the agent."
  type        = bool
  default     = true
}

variable "pod_identity_agent_version" {
  description = "Optional explicit EKS Pod Identity Agent version. Null selects the latest compatible version."
  type        = string
  default     = null
}

variable "preserve_agent_on_destroy" {
  description = "Preserve the agent software in the cluster if its Terraform resource is destroyed."
  type        = bool
  default     = true
}

variable "manage_palette_global_config" {
  description = "Create the kube-system/palette-global-config ConfigMap required by VerteX."
  type        = bool
  default     = true
}

variable "node_role_names" {
  description = "Optional EKS node IAM role names that need the minimal EKS Auth permission for the agent. Leave empty when AmazonEKSWorkerNodePolicy already supplies it."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for role_name in var.node_role_names :
      can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", role_name))
    ])
    error_message = "Every node_role_names value must be a valid IAM role name."
  }
}

variable "tags" {
  description = "Additional tags for AWS resources."
  type        = map(string)
  default     = {}
}

