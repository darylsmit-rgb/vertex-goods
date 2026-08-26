# Palette VerteX EKS Pod Identity IAM setup

This folder provides two equivalent deployment paths:

- [Terraform](TERRAFORM.md) for declarative management of an existing VerteX
  EKS management cluster.
- `create-vertex-pod-identity-roles.sh` for an AWS CLI-driven setup.

This folder creates the three IAM roles required when Palette VerteX and its
EKS workload clusters use the **same AWS account**:

1. `SpectroCloudPaletteRole` - provisions and manages EKS workload clusters.
2. `SpectroCloudHubbleRole` - validates the AWS cloud account.
3. `SpectroCloudIdentityRole` - allows the Identity service to pass the Palette
   role. This role is created last because its policy contains the Palette role
   ARN.

All three roles trust `pods.eks.amazonaws.com`. The script does not create or
associate an IAM OpenID Connect (OIDC) provider.

## Shell-script prerequisites

- Palette VerteX runs on an EKS management cluster in the same AWS account.
- AWS CLI v2 and `jq` are installed and authenticated.
- The caller can manage IAM roles/policies and EKS Pod Identity associations.
- The `eks-pod-identity-agent` add-on is active on the management cluster.
- The EKS node IAM role includes `eks-auth:AssumeRoleForPodIdentity` (the current
  AWS-managed `AmazonEKSWorkerNodePolicy` includes this permission).
- The management cluster has the `kube-system/palette-global-config` ConfigMap
  with `managementClusterName` set to the EKS management-cluster name.

Install or update the agent if needed:

```bash
aws eks create-addon \
  --cluster-name <management-cluster-name> \
  --addon-name eks-pod-identity-agent \
  --region <aws-region>
```

If the add-on already exists, use `aws eks update-addon` instead.

## Run the shell script

For an existing VPC (the default and least-privilege network mode):

```bash
./create-vertex-pod-identity-roles.sh \
  --cluster-name <management-cluster-name> \
  --region us-gov-west-1 \
  --network-mode existing \
  --name-suffix navy \
  --yes
```

Run the command from the directory containing this README. The script resolves
all policy paths relative to its own location, so it can also be invoked from a
different working directory.

Use `--network-mode create` if Palette must create the VPC and networking. Use
`--skip-associations` if the management cluster is not ready yet and you only
want to create the IAM resources.

The script is repeatable. It updates the role trust and inline policies,
versions the customer-managed policies only when their documents change, and
creates or updates these associations:

| Namespace | Service account | Role |
| --- | --- | --- |
| `hubble-system` | `spectro-hubble` | Hubble |
| `palette-identity` | `palette-identity` | Identity |

The Palette role is intentionally **not** associated by this script. VerteX
creates its association when it uses the registered AWS cloud account.

In VerteX, select **EKS Pod Identity** for the AWS account and enter the Palette
role ARN printed by the script. Leave **Add IAM Policies** blank because the
required permissions are already attached.

## OIDC clarification

Spectro Cloud's published minimum EKS lifecycle policy currently contains IAM
permissions to inspect and manage OIDC providers. Having those permissions does
not create an OIDC provider, and this script never calls any IAM OIDC-provider
API. The workload EKS cluster profile must still disable automatic association:

```yaml
managedControlPlane:
  disableAssociateOIDCProvider: true
```

EKS still exposes its built-in cluster issuer URL; the relevant outcome is that
there is no matching IAM OIDC provider registered in the AWS account and pods
use EKS Pod Identity associations instead of IRSA.

## Scope

This script is for the documented three-role **same-account** topology. A
cross-account topology requires four roles with different trust policies and is
not handled here.
# vertex-goods
