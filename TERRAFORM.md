# Terraform deployment order

Run the three Terraform roots in order. Separate state files are intentional:
the management cluster must be configured before VerteX can validate the cloud
account, and the EKS workload cluster must exist before its Kubernetes provider
can be initialized.

## Prerequisites

- Terraform 1.5 or later.
- AWS CLI credentials authorized for IAM, EKS, and any requested VPC endpoints.
- A working kubeconfig-equivalent IAM principal for the management cluster.
- A Palette VerteX API key with tenant-admin and target-project permissions.
- An existing, known-good project-scoped EKS infrastructure profile to clone.
- A source profile with exactly one `kubernetes-eks` pack, containing the
  `managedControlPlane:` and `managedMachinePool:` document keys.
- No `irsaRoles` entry or `eks.amazonaws.com/role-arn` annotation in the source
  profile. Migrate those identities before this stack is applied.
- At least one IAM user that will receive `system:masters` access to workload
  clusters.

Use an environment variable instead of placing the VerteX API key in a tfvars
file:

```bash
export SPECTROCLOUD_APIKEY='<vertex-api-key>'
```

## Stage 1: management cluster

From this directory:

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out management.tfplan
terraform apply management.tfplan
```

Save these outputs for Stage 2:

```bash
terraform output -raw palette_role_arn
terraform output -raw pod_identity_node_policy_arn
```

If the management add-on, roles, policies, associations, or ConfigMap already
exist, import them before applying. See the import section below.

After apply, restart the existing Hubble and Identity pods and verify their
injected credential variables using [COMMANDS.md](COMMANDS.md).

## Stage 2: VerteX profile and EKS workload cluster

The stack clones every layer and value from an existing EKS infrastructure
profile. It changes only the `kubernetes-eks` layer in the new version. This is
safer than attempting to guess pack versions that are available in a specific
air-gapped VerteX registry. Palette EKS values are a multi-document YAML stream;
the code preserves that stream and inserts the required keys rather than
decoding and re-encoding it.

```bash
cd vertex-workload
cp terraform.tfvars.example terraform.tfvars
```

Set:

- `palette_role_arn` from Stage 1.
- `pod_identity_node_policy_arn` from Stage 1.
- the source profile name/version and a new target version.
- the real VerteX API endpoint and project.
- the administrator IAM users.
- static or dynamic AWS placement values.

Then run:

```bash
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out vertex-workload.tfplan
terraform apply vertex-workload.tfplan
```

The new profile version contains these effective Kubernetes-pack settings:

```yaml
managedControlPlane:
  disableAssociateOIDCProvider: true
  iamAuthenticatorConfig:
    mapUsers:
      - userarn: arn:aws-us-gov:iam::<account-id>:user/<admin-user>
        username: <kubernetes-username>
        groups:
          - system:masters
managedMachinePool:
  roleAdditionalPolicies:
    - arn:aws-us-gov:iam::<account-id>:policy/EKSPodIdentityAgentNode-<suffix>
```

Palette should create the `eks-pod-identity-agent` managed add-on while
deploying through the Pod Identity cloud account. Validate this before Stage 3.

If the cloud account is already registered in VerteX, import it rather than
creating a duplicate:

```bash
terraform import spectrocloud_cloudaccount_aws.pod_identity \
  '<cloud-account-id>:tenant'
```

## Stage 3: application identities

Run this stage only after the workload cluster is fully running in both VerteX
and AWS:

```bash
cd ../workload-identities
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out workload-identities.tfplan
terraform apply workload-identities.tfplan
```

Each `pod_identities` entry can create:

- a namespace;
- a service account without an IRSA annotation;
- an IAM role trusting `pods.eks.amazonaws.com`;
- managed and/or inline IAM permissions; and
- an EKS Pod Identity association.

Set `create_service_account = false` when an operator or AWS add-on already
creates the service account.

`nlb_services` is optional. Each entry creates a Kubernetes
`type: LoadBalancer` Service with `aws-load-balancer-type: nlb` set at creation
time, so the native EKS service controller creates an NLB rather than a Classic
Load Balancer. Do not use it to adopt an existing Service by merely changing
the annotation; create/import the correctly annotated Service deliberately.

The workload profile already applies the node policy through
`managedMachinePool.roleAdditionalPolicies`, so `attach_node_policy` defaults
to `false`. Enable it only when adopting a cluster whose profile omitted that
policy.

## Import existing management resources

IAM roles and inline policies:

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

Customer-managed policies for the default GovCloud/static configuration:

```bash
terraform import aws_iam_policy.palette_lifecycle \
  'arn:aws-us-gov:iam::<account-id>:policy/PaletteMinimumEKS-minimum-static-navy'
terraform import aws_iam_role_policy_attachment.palette_lifecycle \
  'SpectroCloudPaletteRole/arn:aws-us-gov:iam::<account-id>:policy/PaletteMinimumEKS-minimum-static-navy'

terraform import 'aws_iam_policy.palette_cloudformation[0]' \
  'arn:aws-us-gov:iam::<account-id>:policy/PaletteCAPACloudFormation-navy'
terraform import 'aws_iam_role_policy_attachment.palette_cloudformation[0]' \
  'SpectroCloudPaletteRole/arn:aws-us-gov:iam::<account-id>:policy/PaletteCAPACloudFormation-navy'

terraform import 'aws_iam_policy.pod_identity_agent_node[0]' \
  'arn:aws-us-gov:iam::<account-id>:policy/EKSPodIdentityAgentNode-navy'
```

Management add-on and ConfigMap:

```bash
terraform import 'aws_eks_addon.pod_identity_agent[0]' \
  '<management-cluster-name>:eks-pod-identity-agent'
terraform import 'kubernetes_config_map_v1.palette_global_config[0]' \
  'kube-system/palette-global-config'
```

Find association IDs, then import them:

```bash
aws eks list-pod-identity-associations \
  --cluster-name '<management-cluster-name>' \
  --region '<aws-region>' \
  --output table

terraform import aws_eks_pod_identity_association.hubble \
  '<management-cluster-name>,<hubble-association-id>'
terraform import aws_eks_pod_identity_association.identity \
  '<management-cluster-name>,<identity-association-id>'
```

## Import existing VerteX or workload resources

If the Pod Identity cloud account is already registered, import it rather than
creating another account:

```bash
cd vertex-workload
terraform import spectrocloud_cloudaccount_aws.pod_identity \
  '<cloud-account-id>:tenant'
```

If Stage 3 should take ownership of the add-on Palette already created:

```bash
cd workload-identities
terraform import 'aws_eks_addon.pod_identity_agent[0]' \
  '<workload-cluster-name>:eks-pod-identity-agent'
```

Set `manage_pod_identity_agent = true` before that import. Always inspect the
first plan after an import and do not apply if Terraform proposes replacement
of an existing IAM role, cluster, or profile version.
