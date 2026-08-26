output "agent_version" {
  description = "Terraform-managed EKS Pod Identity Agent version, or null when Palette owns it."
  value       = try(aws_eks_addon.pod_identity_agent[0].addon_version, null)
}

output "node_role_names" {
  description = "Discovered workload-cluster EKS managed node-group role names."
  value       = sort(tolist(local.workload_node_role_names))
}

output "pod_identity_role_arns" {
  description = "IAM role ARN for each configured workload identity."
  value = {
    for identity_key, role in aws_iam_role.identity : identity_key => role.arn
  }
}

output "pod_identity_association_ids" {
  description = "EKS Pod Identity association ID for each workload identity."
  value = {
    for identity_key, association in aws_eks_pod_identity_association.identity :
    identity_key => association.association_id
  }
}

output "nlb_hostnames" {
  description = "AWS NLB hostnames created for optional Kubernetes services."
  value = {
    for service_key, service in kubernetes_service_v1.nlb :
    service_key => try(service.status[0].load_balancer[0].ingress[0].hostname, null)
  }
}
