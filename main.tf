locals {
  common_tags = merge(
    {
      ManagedBy = "terraform"
      Purpose   = "palette-vertex-pod-identity"
    },
    var.tags
  )

  lifecycle_label           = var.network_mode == "existing" ? "minimum-static" : "minimum-dynamic"
  lifecycle_policy_template = var.network_mode == "existing" ? "${path.module}/policies/palette-minimum-eks-static.json.tpl" : "${path.module}/policies/palette-minimum-eks-dynamic.json.tpl"

  lifecycle_policy = jsonencode(jsondecode(replace(
    file(local.lifecycle_policy_template),
    "__AWS_PARTITION__",
    data.aws_partition.current.partition
  )))

  identity_policy = jsonencode(jsondecode(replace(
    file("${path.module}/policies/identity.json.tpl"),
    "__PALETTE_ROLE_ARN__",
    aws_iam_role.palette.arn
  )))
}

# Role 1: Palette. The Hubble role explicitly depends on the completed Palette
# role policy set so Terraform preserves Spectro Cloud's documented order.
resource "aws_iam_role" "palette" {
  name               = var.palette_role_name
  description        = "Palette VerteX EKS Pod Identity role"
  assume_role_policy = file("${path.module}/policies/trust.json")

  tags = {
    Component = "palette"
  }
}

resource "aws_iam_policy" "palette_lifecycle" {
  name        = "PaletteMinimumEKS-${local.lifecycle_label}-${var.name_suffix}"
  description = "Spectro Cloud minimum EKS permissions (${local.lifecycle_label})"
  policy      = local.lifecycle_policy

  tags = {
    Component = "palette"
  }
}

resource "aws_iam_role_policy_attachment" "palette_lifecycle" {
  role       = aws_iam_role.palette.name
  policy_arn = aws_iam_policy.palette_lifecycle.arn
}

resource "aws_iam_policy" "palette_cloudformation" {
  count = var.manage_cloudformation ? 1 : 0

  name        = "PaletteCAPACloudFormation-${var.name_suffix}"
  description = "Spectro Cloud automatic CAPA CloudFormation management"
  policy      = file("${path.module}/policies/palette-cloudformation-automatic.json")

  tags = {
    Component = "palette"
  }
}

resource "aws_iam_role_policy_attachment" "palette_cloudformation" {
  count = var.manage_cloudformation ? 1 : 0

  role       = aws_iam_role.palette.name
  policy_arn = aws_iam_policy.palette_cloudformation[0].arn
}

resource "aws_iam_role_policy" "palette_pod_identity" {
  name   = "SpectroCloudPodIdentity"
  role   = aws_iam_role.palette.name
  policy = file("${path.module}/policies/palette-pod-identity.json")
}

# Role 2: Hubble.
resource "aws_iam_role" "hubble" {
  name               = var.hubble_role_name
  description        = "Palette VerteX Hubble EKS Pod Identity role"
  assume_role_policy = file("${path.module}/policies/trust.json")

  tags = {
    Component = "hubble"
  }

  depends_on = [
    aws_iam_role_policy_attachment.palette_lifecycle,
    aws_iam_role_policy_attachment.palette_cloudformation,
    aws_iam_role_policy.palette_pod_identity
  ]
}

resource "aws_iam_role_policy" "hubble_validation" {
  name   = "SpectroCloudHubbleValidation"
  role   = aws_iam_role.hubble.name
  policy = file("${path.module}/policies/hubble.json")
}

# Role 3: Identity. Its permissions reference the Palette role ARN and it waits
# for the Hubble role's permissions, preserving Palette -> Hubble -> Identity.
resource "aws_iam_role" "identity" {
  name               = var.identity_role_name
  description        = "Palette VerteX Identity EKS Pod Identity role"
  assume_role_policy = file("${path.module}/policies/trust.json")

  tags = {
    Component = "identity"
  }

  depends_on = [aws_iam_role_policy.hubble_validation]
}

resource "aws_iam_role_policy" "identity" {
  name   = "SpectroCloudIdentity"
  role   = aws_iam_role.identity.name
  policy = local.identity_policy
}

# The agent runs on the existing EKS management cluster. It does not use an
# IRSA service_account_role_arn; its EKS Auth permission comes from node roles.
data "aws_eks_addon_version" "pod_identity_agent" {
  count = var.manage_pod_identity_agent ? 1 : 0

  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = data.aws_eks_cluster.management.version
  most_recent        = true
}

resource "aws_eks_addon" "pod_identity_agent" {
  count = var.manage_pod_identity_agent ? 1 : 0

  cluster_name                = var.management_cluster_name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = coalesce(var.pod_identity_agent_version, data.aws_eks_addon_version.pod_identity_agent[0].version)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  preserve                    = var.preserve_agent_on_destroy

  tags = {
    Component = "eks-pod-identity-agent"
  }
}

# Optional least-privilege permission for management-cluster node roles that do
# not already have it through AmazonEKSWorkerNodePolicy.
resource "aws_iam_policy" "pod_identity_agent_node" {
  count = length(var.node_role_names) > 0 ? 1 : 0

  name        = "EKSPodIdentityAgentNode-${var.name_suffix}"
  description = "Allow EKS nodes to call AssumeRoleForPodIdentity"
  policy      = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Sid      = "EKSPodIdentityAgent"
        Effect   = "Allow"
        Action   = "eks-auth:AssumeRoleForPodIdentity"
        Resource = "*"
      }
    ]
  })

  tags = {
    Component = "eks-pod-identity-agent"
  }
}

resource "aws_iam_role_policy_attachment" "pod_identity_agent_node" {
  for_each = var.node_role_names

  role       = each.value
  policy_arn = aws_iam_policy.pod_identity_agent_node[0].arn
}

# Spectro Cloud requires this ConfigMap to identify the EKS management cluster.
resource "kubernetes_config_map_v1" "palette_global_config" {
  count = var.manage_palette_global_config ? 1 : 0

  metadata {
    name      = "palette-global-config"
    namespace = "kube-system"

    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  data = {
    managementClusterName = var.management_cluster_name
  }
}

# Only the Hubble and Identity service accounts are associated initially. The
# Palette role association is created later by VerteX when the account is used.
resource "aws_eks_pod_identity_association" "hubble" {
  cluster_name    = var.management_cluster_name
  namespace       = "hubble-system"
  service_account = "spectro-hubble"
  role_arn        = aws_iam_role.hubble.arn

  tags = {
    Component = "hubble"
  }

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.hubble_validation
  ]
}

resource "aws_eks_pod_identity_association" "identity" {
  cluster_name    = var.management_cluster_name
  namespace       = "palette-identity"
  service_account = "palette-identity"
  role_arn        = aws_iam_role.identity.arn

  tags = {
    Component = "identity"
  }

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.identity
  ]
}
