variable "aws_region" {
  description = "AWS region for the workload cluster."
  type        = string
}

variable "aws_profile" {
  description = "Optional AWS CLI profile used to create VPC endpoints and detect the partition."
  type        = string
  default     = null
}

variable "spectrocloud_host" {
  description = "Palette VerteX API endpoint, for example https://vertex.example.mil."
  type        = string
}

variable "spectrocloud_project_name" {
  description = "VerteX project that owns the profile and cluster."
  type        = string
}

variable "cloud_account_name" {
  description = "Tenant-scoped VerteX AWS cloud account name."
  type        = string
}

variable "palette_role_arn" {
  description = "SpectroCloudPaletteRole ARN produced by the management-cluster stack."
  type        = string

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov):iam::[0-9]{12}:role/", var.palette_role_arn))
    error_message = "palette_role_arn must be an AWS or AWS GovCloud IAM role ARN."
  }
}

variable "pod_identity_node_policy_arn" {
  description = "Reusable node policy ARN produced by the management-cluster stack."
  type        = string
}

variable "permission_boundary_arn" {
  description = "Optional permission boundary associated with the VerteX cloud account."
  type        = string
  default     = null
}

variable "source_profile_name" {
  description = "Existing project-scoped EKS infrastructure profile to clone."
  type        = string
}

variable "source_profile_version" {
  description = "Existing EKS profile version to clone."
  type        = string
}

variable "target_profile_name" {
  description = "Name for the Pod Identity EKS profile. Use the source name to create a new version in the same lineage."
  type        = string
}

variable "target_profile_version" {
  description = "New semantic version for the Pod Identity profile."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.target_profile_version))
    error_message = "target_profile_version must use major.minor.patch format."
  }
}

variable "kubernetes_pack_name" {
  description = "Internal name of the EKS Kubernetes pack in the source profile."
  type        = string
  default     = "kubernetes-eks"
}

variable "administrator_users" {
  description = "IAM users mapped to Kubernetes administrators. At least one is required by Palette with Pod Identity."
  type = list(object({
    userarn  = string
    username = string
    groups   = optional(list(string), ["system:masters"])
  }))

  validation {
    condition     = length(var.administrator_users) > 0
    error_message = "At least one administrator user is required."
  }
}

variable "workload_cluster_name" {
  description = "Name of the EKS workload cluster created by VerteX."
  type        = string
}

variable "ssh_key_name" {
  description = "Existing EC2 key-pair name. Set null if SSH access is not required."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "Existing VPC ID for static placement. Set null for dynamic placement."
  type        = string
  default     = null
}

variable "availability_zones" {
  description = "Availability zones for dynamic placement. Leave empty when az_subnets is used."
  type        = list(string)
  default     = []
}

variable "az_subnets" {
  description = "Map of availability zone to subnet ID for static placement."
  type        = map(string)
  default     = {}
}

variable "endpoint_access" {
  description = "EKS Kubernetes API endpoint access mode."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["private", "public", "private_and_public"], var.endpoint_access)
    error_message = "endpoint_access must be private, public, or private_and_public."
  }
}

variable "public_access_cidrs" {
  description = "CIDRs permitted to use the public Kubernetes API endpoint."
  type        = set(string)
  default     = []
}

variable "private_access_cidrs" {
  description = "CIDRs permitted to use the private Kubernetes API endpoint."
  type        = set(string)
  default     = []
}

variable "encryption_config_arn" {
  description = "Optional KMS key ARN for EKS secrets encryption."
  type        = string
  default     = null
}

variable "machine_pool" {
  description = "Managed worker-node pool. When autoscaling, count must equal min."
  type = object({
    name          = string
    count         = number
    min           = number
    max           = number
    instance_type = string
    disk_size_gb  = number
    capacity_type = optional(string, "on-demand")
    ami_type      = optional(string, "AL2023_x86_64_STANDARD")
  })
}

variable "vpc_endpoint_config" {
  description = "Optional endpoint placement for workload nodes without NAT/internet egress."
  type = object({
    vpc_id             = string
    subnet_ids         = set(string)
    security_group_ids = set(string)
    route_table_ids    = set(string)
  })
  default  = null
  nullable = true
}

variable "interface_endpoint_services" {
  description = "Interface services created when vpc_endpoint_config is set."
  type        = set(string)
  default     = ["eks-auth"]
}

variable "gateway_endpoint_services" {
  description = "Gateway services created when vpc_endpoint_config is set. Add s3 when pulling ECR layers without NAT."
  type        = set(string)
  default     = []
}

variable "spectrocloud_tags" {
  description = "Palette tags in key:value format."
  type        = set(string)
  default     = ["identity:pod-identity", "managed-by:terraform"]
}

variable "aws_tags" {
  description = "Additional tags for AWS resources created by this stack."
  type        = map(string)
  default     = {}
}
