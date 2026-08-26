# Terraform: VerteX management-cluster Pod Identity

These Terraform files configure an **existing** EKS management cluster that
hosts Palette VerteX. They do not create the VPC, EKS management cluster, or its
node groups.

Terraform manages:

- the Palette, Hubble, and Identity roles in that exact order;
- Palette EKS lifecycle, optional CAPA CloudFormation, and Pod Identity policy;
- Hubble validation and Identity service policies;
- the EKS Pod Identity Agent, unless a Palette cluster profile owns it;
- the `kube-system/palette-global-config` ConfigMap;
- the Hubble and Identity Pod Identity associations; and
- optional `eks-auth:AssumeRoleForPodIdentity` permission for node roles.

It does not create an IAM OIDC provider or a Palette-role association. VerteX
creates the Palette association when it uses the registered cloud account.

## New deployment

```bash
cp terraform.tfvars.example terraform.tfvars
```

Run this from the directory containing this guide. Edit `terraform.tfvars`, then
run:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out pod-identity.tfplan
terraform apply pod-identity.tfplan
```

Register the `palette_role_arn` output in VerteX under **Tenant Settings > Cloud
Accounts > AWS > EKS Pod Identity**. Leave **Add IAM Policies** blank.

## Agent ownership

If the EKS Pod Identity Agent was installed through a Palette management-cluster
profile, keep ownership there and set:

```hcl
manage_pod_identity_agent = false
```

If Terraform should own an existing AWS-managed add-on, import it before
planning:

```bash
terraform import \
  'aws_eks_addon.pod_identity_agent[0]' \
  '<management-cluster-name>:eks-pod-identity-agent'
```

Do not set `service_account_role_arn` on this add-on. The agent uses the node IAM
role's EKS Auth permission and does not use IRSA.

## Import resources created by the shell script

The shell script and Terraform use the same default names and policy documents,
but Terraform must import existing AWS resources before it can manage them.

```bash
terraform import aws_iam_role.palette SpectroCloudPaletteRole
terraform import aws_iam_role.hubble SpectroCloudHubbleRole
terraform import aws_iam_role.identity SpectroCloudIdentityRole

terraform import aws_iam_role_policy.palette_pod_identity \
  'SpectroCloudPaletteRole:SpectroCloudPodIdentity'
terraform import aws_iam_role_policy.hubble_validation \
  'SpectroCloudHubbleRole:SpectroCloudHubbleValidation'
terraform import aws_iam_role_policy.identity \
  'SpectroCloudIdentityRole:SpectroCloudIdentity'
```

Import the customer-managed lifecycle policy using its full ARN. For the
default GovCloud existing-VPC configuration:

```bash
terraform import aws_iam_policy.palette_lifecycle \
  'arn:aws-us-gov:iam::<account-id>:policy/PaletteMinimumEKS-minimum-static-navy'

terraform import aws_iam_role_policy_attachment.palette_lifecycle \
  'SpectroCloudPaletteRole/arn:aws-us-gov:iam::<account-id>:policy/PaletteMinimumEKS-minimum-static-navy'
```

When `manage_cloudformation = true`, also import:

```bash
terraform import 'aws_iam_policy.palette_cloudformation[0]' \
  'arn:aws-us-gov:iam::<account-id>:policy/PaletteCAPACloudFormation-navy'

terraform import 'aws_iam_role_policy_attachment.palette_cloudformation[0]' \
  'SpectroCloudPaletteRole/arn:aws-us-gov:iam::<account-id>:policy/PaletteCAPACloudFormation-navy'
```

Find and import each existing association:

```bash
aws eks list-pod-identity-associations \
  --cluster-name <management-cluster-name> \
  --region <aws-region>

terraform import aws_eks_pod_identity_association.hubble \
  '<management-cluster-name>,<hubble-association-id>'

terraform import aws_eks_pod_identity_association.identity \
  '<management-cluster-name>,<identity-association-id>'
```

If `palette-global-config` already exists and Terraform should own it:

```bash
terraform import 'kubernetes_config_map_v1.palette_global_config[0]' \
  'kube-system/palette-global-config'
```

Always review the first plan after importing. Do not apply until Terraform
shows that it will update the intended roles rather than replace them.

## After apply

Existing Hubble and Identity pods may predate their associations. Recreate them
so EKS injects the Pod Identity credential variables, then verify:

```bash
kubectl delete pods -n hubble-system -l app=spectro-hubble
kubectl delete pods -n palette-identity -l app=palette-identity

kubectl get pods -n hubble-system -l app=spectro-hubble \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}' |
  tr ' ' '\n' |
  grep AWS_CONTAINER
```

Expected variables:

```text
AWS_CONTAINER_CREDENTIALS_FULL_URI
AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
```
