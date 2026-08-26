output "aws_account_id" {
  description = "AWS account containing the management cluster and IAM roles."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_partition" {
  description = "Detected AWS partition, such as aws or aws-us-gov."
  value       = data.aws_partition.current.partition
}

output "management_cluster_name" {
  description = "Existing EKS management cluster configured for Pod Identity."
  value       = var.management_cluster_name
}

output "palette_role_arn" {
  description = "Enter this ARN when registering the EKS Pod Identity AWS account in VerteX."
  value       = aws_iam_role.palette.arn
}

output "hubble_role_arn" {
  description = "IAM role associated with hubble-system/spectro-hubble."
  value       = aws_iam_role.hubble.arn
}

output "identity_role_arn" {
  description = "IAM role associated with palette-identity/palette-identity."
  value       = aws_iam_role.identity.arn
}

output "hubble_association_id" {
  description = "EKS Pod Identity association ID for the Hubble service."
  value       = aws_eks_pod_identity_association.hubble.association_id
}

output "identity_association_id" {
  description = "EKS Pod Identity association ID for the Identity service."
  value       = aws_eks_pod_identity_association.identity.association_id
}

output "pod_identity_agent_version" {
  description = "Terraform-managed agent version, or null when a cluster profile owns the agent."
  value       = try(aws_eks_addon.pod_identity_agent[0].addon_version, null)
}

output "pod_identity_node_policy_arn" {
  description = "Policy ARN to add to workload-cluster node roles in the VerteX EKS profile."
  value       = try(aws_iam_policy.pod_identity_agent_node[0].arn, null)
}

output "management_node_role_names" {
  description = "Management-cluster node roles receiving the EKS Auth permission."
  value       = sort(tolist(local.management_node_role_names))
}

output "management_eks_auth_vpc_endpoint_id" {
  description = "EKS Auth VPC endpoint ID when Terraform creates one."
  value       = try(aws_vpc_endpoint.management_eks_auth[0].id, null)
}
