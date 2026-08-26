variable "aws_region" {
  description = "AWS region containing the EKS workload cluster."
  type        = string
}

variable "aws_profile" {
  description = "Optional AWS CLI profile used by the AWS provider."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Existing EKS workload cluster deployed by VerteX."
  type        = string
}

variable "manage_pod_identity_agent" {
  description = "Manage the EKS Pod Identity Agent add-on here. Leave false when Palette owns it."
  type        = bool
  default     = false
}

variable "pod_identity_agent_version" {
  description = "Optional exact EKS add-on version such as v1.4.0-eksbuild.1. Null selects the latest compatible version."
  type        = string
  default     = null
}

variable "preserve_agent_on_destroy" {
  description = "Preserve the EKS add-on when removing it from Terraform state."
  type        = bool
  default     = true
}

variable "attach_node_policy" {
  description = "Attach the explicit EKS Auth policy to discovered node-group roles. Leave false when the VerteX cluster profile already added it through roleAdditionalPolicies."
  type        = bool
  default     = false
}

variable "pod_identity_node_policy_arn" {
  description = "Reusable eks-auth:AssumeRoleForPodIdentity policy ARN from the management stack."
  type        = string
}

variable "pod_identities" {
  description = "Application IAM roles, service accounts, policies, and EKS Pod Identity associations."
  type = map(object({
    namespace                       = string
    service_account                 = string
    role_name                       = string
    description                     = optional(string, "EKS workload Pod Identity role")
    managed_policy_arns             = optional(set(string), [])
    inline_policy_json              = optional(string)
    create_namespace                = optional(bool, false)
    create_service_account          = optional(bool, true)
    automount_service_account_token = optional(bool, true)
    labels                          = optional(map(string), {})
    annotations                     = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for identity in values(var.pod_identities) :
      can(jsondecode(identity.inline_policy_json))
      if identity.inline_policy_json != null
    ])
    error_message = "Every inline_policy_json value must contain valid JSON."
  }
}

variable "nlb_services" {
  description = "Optional Kubernetes LoadBalancer Services forced to use the native EKS Network Load Balancer implementation rather than a Classic Load Balancer."
  type = map(object({
    name                        = string
    namespace                   = string
    selector                    = map(string)
    scheme                      = optional(string, "internal")
    external_traffic_policy     = optional(string, "Cluster")
    load_balancer_source_ranges = optional(list(string), [])
    subnet_ids                  = optional(list(string), [])
    annotations                 = optional(map(string), {})
    ports = list(object({
      name        = string
      port        = number
      target_port = string
      protocol    = optional(string, "TCP")
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for service in values(var.nlb_services) :
      contains(["internal", "internet-facing"], service.scheme)
    ])
    error_message = "Each NLB scheme must be internal or internet-facing."
  }

  validation {
    condition = alltrue([
      for service in values(var.nlb_services) :
      contains(["Cluster", "Local"], service.external_traffic_policy)
    ])
    error_message = "Each external_traffic_policy must be Cluster or Local."
  }
}

variable "tags" {
  description = "Additional AWS tags."
  type        = map(string)
  default     = {}
}
