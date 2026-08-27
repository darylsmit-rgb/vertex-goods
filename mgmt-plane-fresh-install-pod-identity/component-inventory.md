# Component inventory — mgmt-plane on Pod Identity

Every mgmt-cluster component that calls AWS, in one table. Each row is one arrow
on the arch diagram. Use this when deciding what to grant and how to verify each
piece independently.

## Mgmt-plane chart pods

| Component | Namespace | ServiceAccount | AWS endpoints called | Perms needed | Recommended auth | Why |
|---|---|---|---|---|---|---|
| **spectro-hubble** | `hubble-system` | `spectro-hubble` | EC2 (Describe*), EKS (Describe*), IAM (Get*, List*), KMS (Describe*, List*) | Read-only cloud account validation | **Pod Identity** → `SpectroCloudHubbleRole` | Cleanest; no static creds; auto-refresh |
| **palette-identity** | `palette-identity` | `palette-identity` | EKS (Pod Identity Association CRUD), EC2 (DescribeInstances), IAM (GetRole, PassRole on SpectroCloudPaletteRole) | Manage Pod Identity Associations on workload clusters | **Pod Identity** → `SpectroCloudIdentityRole` | Cleanest; enables Palette to manage PI on workload clusters it provisions |
| **capa-controller-manager** | `capa-system` | `capa-controller-manager` | EC2 (VPC/subnet/SG/NAT/IGW CRUD), EKS (CreateCluster/Nodegroup), IAM (CreateRole/AttachPolicy/PassRole), ELB (CreateLoadBalancer), autoscaling | Workload cluster provisioning | **Pod Identity** → `SpectroCloudPaletteRole` | Broadest perms surface — Pod Identity avoids the static-key blast radius here most of all |
| **specman** | `default` (or as chart names) | (chart-default) | ECR (BatchGetImage, GetAuthToken, GetDownloadUrlForLayer, Describe*) | Pull packs from OCI registry | **Chart values** (config.ociImageRegistry.username/password) | Chart-native; pattern predates Pod Identity |
| **configserver** | `default` | (chart-default) | ECR (same as specman) — one-shot at install (Rule 4) | Seed pack registry docs | **Chart values** — same secret as specman | Runs once at install; upgrade doesn't re-seed |
| **imageswap** | `default` | (chart-default) | ECR (validate image-rewrite rules) | Read | **Chart values** | Same secret path as specman |
| **mongo** | `default` | (chart-default) | — | None directly (EBS PVCs are the CSI's problem) | N/A | — |
| **auth-service** | `default` | (chart-default) | — | None | N/A | — |

## Mgmt-cluster addons (not part of the chart but required)

| Addon | Namespace | ServiceAccount | AWS endpoints | Perms needed | Recommended auth |
|---|---|---|---|---|---|
| **eks-pod-identity-agent** | `kube-system` | (own SA) | STS (AssumeRoleForPodIdentity, on behalf of pods) | System-scope | Managed addon (AWS-provided) |
| **aws-node** (VPC CNI) | `kube-system` | `aws-node` | EC2 (CreateNetworkInterface, AttachNetworkInterface, AssignPrivateIpAddresses, DescribeInstances, DescribeSubnets) | ENI management for pod IPs | **Pod Identity** → VPC CNI role (`AmazonEKS_CNI_Policy`) |
| **ebs-csi-controller** | `kube-system` | `ebs-csi-controller-sa` | EC2 (Create/Attach/Detach/Describe Volume + Snapshot, CreateTags) | Provision + attach block volumes | **Pod Identity** → EBS CSI role (`AmazonEBSCSIDriverPolicy`) |
| **aws-load-balancer-controller** | `kube-system` | `aws-load-balancer-controller` | ELBv2 (CreateLoadBalancer, CreateTargetGroup, RegisterTargets, ModifyListenerAttributes, etc.), EC2 (DescribeSubnets, DescribeSecurityGroups, DescribeVpcs, CreateSecurityGroup, AuthorizeSecurityGroupIngress), IAM (CreateServiceLinkedRole) | NLB/ALB CRUD driven by Service and Ingress annotations | **Pod Identity** → LBC role (`AWSLoadBalancerControllerIAMPolicy`) |
| **efs-csi-controller** (optional) | `kube-system` | `efs-csi-controller-sa` | elasticfilesystem (DescribeMountTargets, DescribeFileSystems, CreateAccessPoint, DeleteAccessPoint) | EFS provisioning | **Pod Identity** → EFS CSI role (`AmazonEFSCSIDriverPolicy`) |

## Cloud Account credentialType — the CAPA auth surface

The Palette Tenant Console → Settings → Cloud Accounts → `credentialType` decides
how CAPA (running on the mgmt cluster) gets AWS creds when it provisions
workload clusters. This is a separate configuration from the mgmt-plane Pod
Identity setup above (though they can share the same IAM role).

| credentialType | Mechanism | Requires | Status on VerteX 4.9.18 |
|---|---|---|---|
| `pod-identity` | CAPA pod's SA has a Pod Identity Association; SDK gets temp creds via the local agent | Pod Identity addon on mgmt cluster; IAM role with `pods.eks.amazonaws.com` trust; Association `capa-controller-manager` → that role | ✅ Working. Recommended. |
| `secret` | Static IAM user AK/SK stored in a K8s Secret in mgmt cluster | IAM user with the CAPA perms above; long-lived AK/SK | ✅ Works everywhere. Simplest but has long-lived keys. |
| `sts` | Source identity assumes target role via cross-account trust + external ID | Source identity, target role, external ID | ❌ **BROKEN on 4.9.18 aws-us-gov** (Rule 10 / PEM-11654). Do not offer. |

## Workload clusters (what Palette provisions)

Palette-managed workload clusters are DIFFERENT from the self-managed mgmt
cluster because CMA + `palette-controller-manager` on the workload cluster
reconcile it back to the cluster-profile's declared state.

| Component | Namespace | Recommended auth | Why |
|---|---|---|---|
| `cluster-management-agent` (CMA) | `cluster-<uid>` | No AWS creds — phones home to mgmt-plane via HTTPS | — |
| `jet` | `jet-system` | No AWS creds — phones home to mgmt-plane | — |
| Workload apps needing AWS | app-specific | **IRSA** (SA annotated with `eks.amazonaws.com/role-arn`) | Palette does not reconcile SA annotations. Pod Identity addon gets stripped within ~4 min unless declared in the cluster profile (Rule 5). IRSA is reconcile-proof. |
| `ebs-csi-controller` | `kube-system` | **IRSA** on `ebs-csi-controller-sa` | Palette reconciles managed-policy attachments off the `spectro__ownerUid`-tagged node role. IRSA on the SA is reconcile-proof (chart-owned annotation). |
| `kpack-bot` (if deploying source-to-image) | `kpack` + workload-namespace | **IRSA** on `kpack-bot` SA | Same reason as EBS-CSI. Static ECR tokens rot every ~12 hours; we've watched this silently break for weeks in the field. See the paihub-kpack-irsa memory file for the incident write-up and the IAM policy shape. |

## What "changes at each AWS endpoint" based on auth choice

For your customer diagram. Each destination endpoint gets a different arrow
depending on which mechanism the source pod uses.

### To STS (all Pod Identity + IRSA flows start here)

| Auth | API call | Header/Env |
|---|---|---|
| Pod Identity | `sts:AssumeRoleForPodIdentity` | Env: `AWS_CONTAINER_CREDENTIALS_FULL_URI` → local agent, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` → projected SA token |
| IRSA | `sts:AssumeRoleWithWebIdentity` | Env: `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` → projected SA token |
| Static AK/SK | (no STS hop) | Env: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

### To ECR

| Auth | Flow |
|---|---|
| Pod Identity | STS temp creds → `ecr:GetAuthorizationToken` → temp docker password valid ~12h → `ecr:BatchGetImage` |
| IRSA | Same shape as Pod Identity; the initial STS call differs (WebIdentity vs. PodIdentity) |
| dockerconfigjson secret | Pod mounts K8s Secret → docker daemon reads pre-baked ECR token → uses directly. Token expires in 12h → silent failure. This is the pattern specman/configserver/imageswap use today via chart values. |
| Node role | Kubelet's ECR credential provider handles POD IMAGE PULL only; does not help in-pod SDK code |

### To EC2 / EKS / IAM / ELB (CAPA + LBC + CSI)

| Auth | Flow |
|---|---|
| Pod Identity | STS temp creds → direct API call (`ec2:CreateVolume` etc.) |
| Static (`credentialType: secret`) | AK/SK loaded from env → direct API call |
| STS (`credentialType: sts`) | Source AK/SK → `sts:AssumeRole` cross-account → temp creds → direct API call. Broken on aws-us-gov (Rule 10). |
