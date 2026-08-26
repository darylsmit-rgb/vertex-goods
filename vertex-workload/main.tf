locals {
  source_kubernetes_packs = [
    for profile_pack in data.spectrocloud_cluster_profile.source.pack :
    profile_pack if profile_pack.name == var.kubernetes_pack_name
  ]

  source_kubernetes_pack   = try(one(local.source_kubernetes_packs), null)
  source_kubernetes_values = try(local.source_kubernetes_pack.values, "")

  requested_map_users = [
    for administrator in var.administrator_users : {
      userarn  = administrator.userarn
      username = administrator.username
      groups   = administrator.groups
    }
  ]

  # Palette's EKS pack values are a YAML document stream separated by `---`.
  # Terraform's yamldecode accepts only one YAML document, so preserve the
  # stream byte-for-byte and insert the required settings into known pack keys.
  requested_map_users_yaml = "      ${indent(
    6,
    trimspace(yamlencode(local.requested_map_users))
  )}"

  source_has_managed_control_plane = can(regex(
    "(?m)^managedControlPlane:[^\\r\\n]*$",
    local.source_kubernetes_values
  ))

  source_has_managed_machine_pool = can(regex(
    "(?m)^managedMachinePool:[^\\r\\n]*$",
    local.source_kubernetes_values
  ))

  kubernetes_values_with_oidc_disabled = strcontains(
    local.source_kubernetes_values,
    "disableAssociateOIDCProvider:"
    ) ? replace(
    local.source_kubernetes_values,
    "/(?m)^  disableAssociateOIDCProvider:[^\\r\\n]*$/",
    "  disableAssociateOIDCProvider: true"
    ) : replace(
    local.source_kubernetes_values,
    "/(?m)^managedControlPlane:[^\\r\\n]*$/",
    "managedControlPlane:\n  disableAssociateOIDCProvider: true"
  )

  kubernetes_values_with_administrators = strcontains(
    local.kubernetes_values_with_oidc_disabled,
    "    mapUsers:"
    ) ? replace(
    local.kubernetes_values_with_oidc_disabled,
    "/(?m)^    mapUsers:[^\\r\\n]*$/",
    "    mapUsers:\n${local.requested_map_users_yaml}"
    ) : strcontains(
    local.kubernetes_values_with_oidc_disabled,
    "  iamAuthenticatorConfig:"
    ) ? replace(
    local.kubernetes_values_with_oidc_disabled,
    "/(?m)^  iamAuthenticatorConfig:[^\\r\\n]*$/",
    "  iamAuthenticatorConfig:\n    mapUsers:\n${local.requested_map_users_yaml}"
    ) : replace(
    local.kubernetes_values_with_oidc_disabled,
    "/(?m)^managedControlPlane:[^\\r\\n]*$/",
    "managedControlPlane:\n  iamAuthenticatorConfig:\n    mapUsers:\n${local.requested_map_users_yaml}"
  )

  kubernetes_pack_values = strcontains(
    local.kubernetes_values_with_administrators,
    "  roleAdditionalPolicies:"
    ) ? replace(
    local.kubernetes_values_with_administrators,
    "/(?m)^  roleAdditionalPolicies:[^\\r\\n]*$/",
    "  roleAdditionalPolicies:\n    - ${jsonencode(var.pod_identity_node_policy_arn)}"
    ) : replace(
    local.kubernetes_values_with_administrators,
    "/(?m)^managedMachinePool:[^\\r\\n]*$/",
    "managedMachinePool:\n  roleAdditionalPolicies:\n    - ${jsonencode(var.pod_identity_node_policy_arn)}"
  )

  source_declares_irsa_roles = can(regex(
    "(?m)^[ \\t]*irsaRoles[ \\t]*:",
    local.source_kubernetes_values
  ))

  source_irsa_annotation_packs = [
    for profile_pack in data.spectrocloud_cluster_profile.source.pack :
    profile_pack.name if strcontains(profile_pack.values, "eks.amazonaws.com/role-arn")
  ]

  rendered_has_oidc_disabled = can(regex(
    "(?m)^  disableAssociateOIDCProvider:[ \\t]*true[ \\t]*$",
    local.kubernetes_pack_values
  ))

  rendered_has_node_policy = strcontains(
    local.kubernetes_pack_values,
    var.pod_identity_node_policy_arn
  )

  rendered_has_administrators = alltrue([
    for administrator in var.administrator_users :
    strcontains(local.kubernetes_pack_values, administrator.userarn)
  ])
}

check "source_contains_one_eks_kubernetes_pack" {
  assert {
    condition     = length(local.source_kubernetes_packs) == 1
    error_message = "The source profile must contain exactly one pack named ${var.kubernetes_pack_name}."
  }
}

# This is the same role ARN produced by the management-cluster stack. Import an
# already registered account rather than creating a duplicate Palette account.
resource "spectrocloud_cloudaccount_aws" "pod_identity" {
  provider = spectrocloud.tenant

  name                    = var.cloud_account_name
  context                 = "tenant"
  type                    = "pod-identity"
  role_arn                = var.palette_role_arn
  partition               = data.aws_partition.current.partition
  permission_boundary_arn = var.permission_boundary_arn
}

# Clone the selected source profile into a new version and change only the EKS
# Kubernetes layer. All other source-profile layers and values are retained in
# their original order.
resource "spectrocloud_cluster_profile" "eks_pod_identity" {
  provider = spectrocloud.project

  name         = var.target_profile_name
  version      = var.target_profile_version
  description  = "EKS infrastructure profile using Pod Identity without an IAM OIDC provider"
  context      = "project"
  cloud        = "eks"
  type         = "infra"
  tags         = var.spectrocloud_tags
  skip_destroy = true

  dynamic "pack" {
    for_each = data.spectrocloud_cluster_profile.source.pack

    content {
      name         = pack.value.name
      tag          = pack.value.tag
      uid          = pack.value.uid
      type         = pack.value.type
      registry_uid = pack.value.registry_uid
      values = pack.value.name == var.kubernetes_pack_name ? (
        local.kubernetes_pack_values
      ) : pack.value.values

      dynamic "manifest" {
        for_each = pack.value.manifest

        content {
          name    = manifest.value.name
          content = manifest.value.content
        }
      }
    }
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition = (
        local.source_has_managed_control_plane &&
        local.source_has_managed_machine_pool
      )
      error_message = "The source EKS pack must contain managedControlPlane: and managedMachinePool: document keys."
    }

    precondition {
      condition     = !local.source_declares_irsa_roles
      error_message = "The source EKS pack declares irsaRoles. Remove or migrate them to EKS Pod Identity before creating an OIDC-free profile."
    }

    precondition {
      condition     = length(local.source_irsa_annotation_packs) == 0
      error_message = "Source profile pack values contain eks.amazonaws.com/role-arn in: ${join(", ", local.source_irsa_annotation_packs)}. Remove or migrate every IRSA annotation first."
    }

    precondition {
      condition = (
        local.rendered_has_oidc_disabled &&
        local.rendered_has_node_policy &&
        local.rendered_has_administrators
      )
      error_message = "Unable to inject all Pod Identity settings into the source EKS pack. Confirm the pack uses the standard two-space managedControlPlane and managedMachinePool structure."
    }
  }
}

# Optional AWS PrivateLink endpoints for static/private placements. At minimum,
# a no-egress Pod Identity cluster needs eks-auth. ECR pulls normally also need
# ecr.api, ecr.dkr, and an S3 gateway endpoint.
resource "aws_vpc_endpoint" "interface" {
  for_each = var.vpc_endpoint_config == null ? toset([]) : var.interface_endpoint_services

  vpc_id              = try(var.vpc_endpoint_config.vpc_id, null)
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = try(var.vpc_endpoint_config.subnet_ids, null)
  security_group_ids  = try(var.vpc_endpoint_config.security_group_ids, null)
  private_dns_enabled = true

  tags = {
    Name = "${var.workload_cluster_name}-${replace(each.value, ".", "-")}"
  }
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = var.vpc_endpoint_config == null ? toset([]) : var.gateway_endpoint_services

  vpc_id            = try(var.vpc_endpoint_config.vpc_id, null)
  service_name      = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = try(var.vpc_endpoint_config.route_table_ids, null)

  tags = {
    Name = "${var.workload_cluster_name}-${replace(each.value, ".", "-")}"
  }
}

resource "spectrocloud_cluster_eks" "workload" {
  provider = spectrocloud.project

  name             = var.workload_cluster_name
  description      = "EKS workload cluster deployed by Palette VerteX with EKS Pod Identity"
  context          = "project"
  tags             = var.spectrocloud_tags
  cloud_account_id = spectrocloud_cloudaccount_aws.pod_identity.id

  cloud_config {
    region                = var.aws_region
    ssh_key_name          = var.ssh_key_name
    vpc_id                = var.vpc_id
    azs                   = length(var.az_subnets) == 0 ? var.availability_zones : null
    az_subnets            = length(var.az_subnets) > 0 ? var.az_subnets : null
    endpoint_access       = var.endpoint_access
    public_access_cidrs   = length(var.public_access_cidrs) > 0 ? var.public_access_cidrs : null
    private_access_cidrs  = length(var.private_access_cidrs) > 0 ? var.private_access_cidrs : null
    encryption_config_arn = var.encryption_config_arn
  }

  cluster_profile {
    id = spectrocloud_cluster_profile.eks_pod_identity.id
  }

  machine_pool {
    name          = var.machine_pool.name
    count         = var.machine_pool.count
    min           = var.machine_pool.min
    max           = var.machine_pool.max
    instance_type = var.machine_pool.instance_type
    disk_size_gb  = var.machine_pool.disk_size_gb
    capacity_type = var.machine_pool.capacity_type
    ami_type      = var.machine_pool.ami_type
    azs           = length(var.az_subnets) == 0 ? var.availability_zones : null
    az_subnets    = length(var.az_subnets) > 0 ? var.az_subnets : null
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "60m"
  }

  depends_on = [
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.gateway
  ]
}
