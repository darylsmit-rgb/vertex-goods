output "cloud_account_id" {
  description = "Tenant-scoped VerteX AWS Pod Identity cloud account ID."
  value       = spectrocloud_cloudaccount_aws.pod_identity.id
}

output "cluster_profile_id" {
  description = "New EKS Pod Identity infrastructure profile version ID."
  value       = spectrocloud_cluster_profile.eks_pod_identity.id
}

output "cluster_profile_version" {
  description = "New EKS Pod Identity profile version."
  value       = var.target_profile_version
}

output "workload_cluster_id" {
  description = "Palette VerteX workload cluster ID."
  value       = spectrocloud_cluster_eks.workload.id
}

output "workload_cluster_name" {
  description = "AWS EKS workload cluster name."
  value       = var.workload_cluster_name
}

output "kubernetes_pack_values" {
  description = "Rendered Kubernetes EKS pack values used in the new profile version."
  value       = local.kubernetes_pack_values
  sensitive   = true
}
