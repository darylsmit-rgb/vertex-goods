locals {
  workload_node_role_names = toset([
    for node_group in data.aws_eks_node_group.workload :
    element(reverse(split("/", node_group.node_role_arn)), 0)
  ])

  managed_namespaces = {
    for namespace in distinct([
      for identity in values(var.pod_identities) : identity.namespace
      if identity.create_namespace
    ]) : namespace => namespace
  }

  managed_service_accounts = {
    for identity_key, identity in var.pod_identities : identity_key => identity
    if identity.create_service_account
  }

  managed_policy_attachments = {
    for attachment in flatten([
      for identity_key, identity in var.pod_identities : [
        for policy_arn in identity.managed_policy_arns : {
          identity_key = identity_key
          policy_arn   = policy_arn
        }
      ]
    ]) : "${attachment.identity_key}:${attachment.policy_arn}" => attachment
  }

  inline_policy_identities = {
    for identity_key, identity in var.pod_identities : identity_key => identity
    if identity.inline_policy_json != null
  }
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    sid    = "AllowEksAuthToAssumeRoleForPodIdentity"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

# Palette normally installs this managed add-on when the cluster is deployed
# through a Pod Identity cloud account. Enable this only if Terraform should own
# it, and import an existing add-on before the first apply.
data "aws_eks_addon_version" "pod_identity_agent" {
  count = var.manage_pod_identity_agent ? 1 : 0

  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = data.aws_eks_cluster.workload.version
  most_recent        = true
}

resource "aws_eks_addon" "pod_identity_agent" {
  count = var.manage_pod_identity_agent ? 1 : 0

  cluster_name                = var.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = coalesce(var.pod_identity_agent_version, data.aws_eks_addon_version.pod_identity_agent[0].version)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  preserve                    = var.preserve_agent_on_destroy

  depends_on = [aws_iam_role_policy_attachment.node_pod_identity]
}

# This is normally redundant with AmazonEKSWorkerNodePolicy. Keeping it explicit
# guarantees the EKS Auth permission when custom/minimal node policies are used.
resource "aws_iam_role_policy_attachment" "node_pod_identity" {
  for_each = var.attach_node_policy ? local.workload_node_role_names : toset([])

  role       = each.value
  policy_arn = var.pod_identity_node_policy_arn
}

resource "kubernetes_namespace_v1" "identity" {
  for_each = local.managed_namespaces

  metadata {
    name = each.value

    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }
}

resource "kubernetes_service_account_v1" "identity" {
  for_each = local.managed_service_accounts

  metadata {
    name        = each.value.service_account
    namespace   = each.value.namespace
    labels      = each.value.labels
    annotations = each.value.annotations
  }

  automount_service_account_token = each.value.automount_service_account_token

  lifecycle {
    precondition {
      condition     = !contains(keys(each.value.annotations), "eks.amazonaws.com/role-arn")
      error_message = "Pod Identity service accounts must not contain the IRSA eks.amazonaws.com/role-arn annotation."
    }
  }

  depends_on = [kubernetes_namespace_v1.identity]
}

resource "aws_iam_role" "identity" {
  for_each = var.pod_identities

  name               = each.value.role_name
  description        = each.value.description
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    Cluster        = var.cluster_name
    Namespace      = each.value.namespace
    ServiceAccount = each.value.service_account
  }
}

resource "aws_iam_role_policy_attachment" "identity" {
  for_each = local.managed_policy_attachments

  role       = aws_iam_role.identity[each.value.identity_key].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "identity" {
  for_each = local.inline_policy_identities

  name   = "${each.value.role_name}-permissions"
  role   = aws_iam_role.identity[each.key].name
  policy = each.value.inline_policy_json
}

resource "aws_eks_pod_identity_association" "identity" {
  for_each = var.pod_identities

  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.identity[each.key].arn

  tags = {
    Identity = each.key
  }

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.identity,
    aws_iam_role_policy.identity,
    kubernetes_service_account_v1.identity
  ]
}

# The in-tree EKS service controller creates a Network Load Balancer when this
# annotation is set to nlb. Without it, a type=LoadBalancer Service can fall
# back to a Classic Load Balancer on clusters that still support that path.
resource "kubernetes_service_v1" "nlb" {
  for_each = var.nlb_services

  metadata {
    name      = each.value.name
    namespace = each.value.namespace
    annotations = merge(
      each.value.annotations,
      {
        "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
      },
      each.value.scheme == "internal" ? {
        "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"
      } : {},
      length(each.value.subnet_ids) > 0 ? {
        "service.beta.kubernetes.io/aws-load-balancer-subnets" = join(",", each.value.subnet_ids)
      } : {}
    )
  }

  spec {
    type                        = "LoadBalancer"
    selector                    = each.value.selector
    external_traffic_policy     = each.value.external_traffic_policy
    load_balancer_source_ranges = length(each.value.load_balancer_source_ranges) > 0 ? each.value.load_balancer_source_ranges : null

    dynamic "port" {
      for_each = each.value.ports

      content {
        name        = port.value.name
        port        = port.value.port
        target_port = port.value.target_port
        protocol    = port.value.protocol
      }
    }
  }

  wait_for_load_balancer = true

  lifecycle {
    precondition {
      condition = lookup(
        each.value.annotations,
        "service.beta.kubernetes.io/aws-load-balancer-type",
        "nlb"
      ) == "nlb"
      error_message = "nlb_services cannot override aws-load-balancer-type with a non-NLB value."
    }
  }

  depends_on = [kubernetes_namespace_v1.identity]
}
