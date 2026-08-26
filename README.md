# Palette VerteX EKS Pod Identity

This package implements EKS Pod Identity for both sides of a same-account
Palette VerteX deployment:

1. the existing EKS cluster hosting Palette VerteX; and
2. EKS workload clusters deployed from VerteX cluster profiles.

No Terraform resource in this package creates an IAM OpenID Connect (OIDC)
provider. Workload profiles set `disableAssociateOIDCProvider: true` before the
EKS cluster is created.

## Directory layout

| Path | Purpose |
| --- | --- |
| Root Terraform files | Configure the existing VerteX management cluster. |
| `vertex-workload/` | Register the AWS Pod Identity cloud account, clone an EKS profile into a no-OIDC version, and deploy an EKS workload cluster from it. |
| `workload-identities/` | Configure the deployed cluster's agent ownership, node permissions, application service accounts, IAM roles, and associations. |
| `policies/` | Relative policy and trust-policy documents used by the management stack and shell script. |
| `COMMANDS.md` | Commands for validation, imports, restarts, and the few operational steps that do not belong in Terraform. |
| `TERRAFORM.md` | Ordered deployment and import instructions. |

The root also retains `create-vertex-pod-identity-roles.sh` as an AWS CLI
alternative for the three management-plane IAM roles.

## What Terraform manages

### Management cluster

- `SpectroCloudPaletteRole`, `SpectroCloudHubbleRole`, and
  `SpectroCloudIdentityRole`, in that dependency order.
- Palette EKS lifecycle, CAPA CloudFormation, account validation, and Pod
  Identity permissions.
- The EKS Pod Identity Agent managed add-on, when enabled.
- The reusable node policy containing
  `eks-auth:AssumeRoleForPodIdentity`.
- Automatic discovery of EKS managed node-group roles and attachment of that
  policy, plus explicitly listed self-managed node roles.
- Optional EKS Auth interface VPC endpoint.
- `kube-system/palette-global-config`.
- The Hubble and Identity service Pod Identity associations.

The Palette role is intentionally not associated with a management-cluster
service account. VerteX uses this role through the registered Pod Identity cloud
account and creates the workload-cluster association it requires.

### VerteX and workload cluster

- Tenant-scoped `pod-identity` AWS cloud-account registration.
- A new version of an existing, known-good EKS infrastructure cluster profile.
- `managedControlPlane.disableAssociateOIDCProvider: true` at creation time.
- At least one IAM administrator under
  `managedControlPlane.iamAuthenticatorConfig.mapUsers`.
- A plan-time guard that rejects a source profile containing Kubernetes-pack
  `irsaRoles` or `eks.amazonaws.com/role-arn` annotations. Those identities
  must be migrated before an OIDC-free profile can be created.
- Addition of the Pod Identity node policy under
  `managedMachinePool.roleAdditionalPolicies`.
- The EKS workload cluster deployed from that profile version.
- Optional interface and gateway VPC endpoints for a no-egress VPC.
- Reusable application IAM roles, Kubernetes service accounts, and EKS Pod
  Identity associations after the cluster is running.
- Optional Kubernetes Services explicitly annotated to create native EKS
  Network Load Balancers (NLBs), preventing the Classic Load Balancer default.

## Important boundaries

- This is the documented three-role **same-account** topology. Cross-account
  deployment requires Palette target/local role chaining and is not implemented
  by these files.
- An EKS cluster always publishes an OIDC issuer URL. The requirement is that no
  matching **IAM OIDC provider** is registered in the AWS account.
- Existing IRSA annotations are not automatically convertible because the
  intended IAM permissions must be reviewed. Use the audit commands in
  `COMMANDS.md`, then represent each workload in `workload-identities`.
- Exactly one system should own the Pod Identity Agent. Palette normally owns it
  on workload clusters deployed through a Pod Identity cloud account. Do not
  also install the Palette Helm pack or create a second managed add-on.
- Store Terraform state in an encrypted, access-controlled backend. Cluster and
  provider resources can place sensitive metadata in state.

## Configure account-level IMDSv2 defaults

AWS configures IMDS defaults per account and per Region.

```bash
export AWS_PROFILE="your-profile"
export AWS_REGION="us-gov-west-1"
export IMDS_HOP_LIMIT="2"

aws ec2 modify-instance-metadata-defaults \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --http-tokens required \
  --http-put-response-hop-limit "$IMDS_HOP_LIMIT"
```

Verify the account defaults:

```bash
aws ec2 get-instance-metadata-defaults \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION"
```

Start with [TERRAFORM.md](TERRAFORM.md).
