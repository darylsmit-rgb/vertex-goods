# Domino on Palette — Cluster Requirements → Profile Mapping

Maps [Domino's Kubernetes cluster requirements](https://docs.dominodatalab.com/en/latest/admin_guide/25b6dc/cluster-requirements/)
to a **Palette cluster profile + EKS cluster** definition (Terraform in this folder).

Target: an EKS host cluster (GovCloud, single-AZ sandbox) that satisfies Domino, with Domino itself
delivered as a Palette **add-on profile** once its airgap images are mirrored.

> **Lineage note:** the AWS **GovCloud (`awsgov`)** cloud-account type is exposed by the **`vertex/`
> (FIPS)** Palette build, not `palette/` (non-FIPS). Provision this from the FIPS management plane.

## Node pools (set on the EKS cluster, not the profile)

| Pool | Count | Spec | Disk | Required labels | Taint |
|---|---|---|---|---|---|
| **platform** | 4 (min=max) | 8 vCPU / 32 GB → `m5.2xlarge` | 128 GB | `dominodatalab.com/node-pool=platform` | — |
| **compute** (default) | ≥1, autoscaling | 8 vCPU / 32 GB → `m5.2xlarge` | 400 GB | `domino/build-node=true`, `dominodatalab.com/node-pool=default` | — |
| **gpu** (optional) | 0–N, autoscaling | 8 vCPU / 16 GB + NVIDIA → `g4dn.2xlarge` | 400 GB | `dominodatalab.com/node-pool=default-gpu`, `nvidia.com/gpu=true` | `nvidia.com/gpu=true:NoSchedule` |

> GPU nodes need the NVIDIA driver + device plugin (NVIDIA GPU Operator add-on, or a GPU-preconfigured AMI).

## Storage (two StorageClasses, exact names)

| Domino name | Type | Requirements | Palette implementation |
|---|---|---|---|
| `dominodisk` | Block | dynamic provisioning, SSD, ≥100 GB volumes, **POSIX (not NFS)** | `csi-aws-ebs` pack → gp3 SC `dominodisk` (`WaitForFirstConsumer`, encrypted) |
| `dominoshared` | Shared | **ReadWriteMany** from all nodes, `volumeBindingMode: Immediate` | `csi-aws-efs` add-on → EFS SC `dominoshared` (`Immediate`, `provisioningMode: efs-ap`); needs an EFS filesystem + mount targets in the cluster subnets |

Both StorageClasses are created by a **manifest pack** in the profile (exact names matter to Domino).

## Networking / ingress

| Requirement | Implementation |
|---|---|
| SSL-terminating LB, 80/443 → 80, WebSocket, `X-Forwarded-Proto`, health `/healthz`=200 | AWS LB (NLB/ALB) in front of the ingress controller; terminate TLS at LB or ingress |
| **NetworkPolicy** support | **`cni-calico`** (Domino recommends Calico). EKS default `aws-vpc-cni` supports NetworkPolicy only on newer versions — use Calico to be safe. |
| DNS | wildcard/record → LB (partition-specific in GovCloud) |
| NTP | enabled on nodes (Amazon Linux EKS AMI has chrony) |

## Namespaces
Domino creates 3: **platform**, **compute**, **installer** (`fleetcommand-agent` manages these).

## Profile layers (this folder's `host-cluster-profile.tf`)
1. `amazon-linux-eks` (OS) — 2. `kubernetes-eks` (1.30/1.31) — 3. **`cni-calico`** (NetworkPolicy) —
4. `csi-aws-ebs` (→ `dominodisk`) — 5. `csi-aws-efs` (→ `dominoshared`) —
6. manifest pack: the two StorageClasses — 7. (optional) NVIDIA GPU Operator.

## Status / blockers
- **Domino images are gated** (`mirrors.domino.tech` airgap tarball needs a Domino account). The
  add-on profile (`domino-addon-profile.tf`) is scaffolded; finalize chart/image refs once the
  `fleetcommand-agent-6.2.2` bundle is obtained and mirrored to ECR (`TARGET_PREFIX=domino`).
- Confirm pack **versions** and `registry_uid` against your Palette pack registry before `apply`.
- Provide the **EFS filesystem id** + subnets for `dominoshared`.
