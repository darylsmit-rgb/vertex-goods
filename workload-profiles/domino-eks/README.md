# Domino Data Lab on EKS — Palette workload cluster profile

Engineering-facing companion to
`info-share/palette-vertex/domino-cluster-profile/`. This directory carries
the Terraform + manifests that author a **Palette cluster profile** for the
EKS host cluster that Domino's own installer (`ddlctl` /
`fleetcommand-agent`) subsequently installs Domino onto. Portable across
commercial AWS and AWS GovCloud partitions.

This file adds the field-experience context that the customer-facing pack in
info-share deliberately omits — what bit us, what to watch for, and how this
profile relates to the other pieces in vertex-goods.

## What this profile is (and isn't)

**Is:** a Palette `spectrocloud_cluster_profile` of type `cluster`, cloud
`eks`, with five layers:

1. OS — `amazon-linux-eks`
2. Kubernetes — `kubernetes-eks`
3. CNI — `cni-calico` (Domino requires NetworkPolicy; Calico is the safest bet)
4. Storage (EBS) — `csi-aws-ebs` pack, values overlay creates the `dominodisk`
   StorageClass Domino needs for RWO/block
5. Storage (EFS) — deployed as an Add-Manifest layer (see gotcha #1 below),
   using Domino's own EFS CSI driver images

Optionally a sixth layer:

6. CoreDNS phone-home Add-Manifest — only emitted when `mgmt_elb_ip` is set.
   Patches `kube-system/coredns` on the tenant cluster so it can reach the
   Palette mgmt-plane hostname when public DNS or a CASB is in the path. See
   the sibling `../../mgmt-plane-nlb-migration/` and info-share's
   `dns-split-horizon/` for the decision matrix on when to use this vs. an
   AWS-native fix (Route53 private hosted zone, PrivateLink, route-table
   carve-out).

**Isn't:** anything that installs Domino itself. Domino ships its own
installer (`ddlctl` / `fleetcommand-agent`) that runs against the cluster
this profile provisions. The `ddlctl` invocation happens outside Terraform.

## How it fits with the rest of vertex-goods

| Piece | Provides | Consumed by this profile |
|---|---|---|
| `../../` (root Terraform) | `SpectroCloudPaletteRole` (CAPA role), Pod Identity Agent addon on the mgmt cluster, node role for Pod Identity | The Palette API this profile talks to must be running on the mgmt cluster set up by root. `sc_host` variable points at it. |
| `../../vertex-workload/` | Registers the AWS cloud account with `credentialType: pod-identity`, creates a workload EKS cluster from a *cloned* infra profile | This profile can serve as the **source** infra profile that `vertex-workload/` clones — or you can attach it directly to a workload cluster spun up outside of `vertex-workload/`. |
| `../../workload-identities/` | On-cluster identity setup for the DEPLOYED workload cluster (SAs, IAM roles, Pod Identity Associations for app workloads) | Post-provisioning. If Domino's operator SAs need AWS access (e.g. the S3 backing for user data), this is where those Associations get made. |
| `../../mgmt-plane-fresh-install-pod-identity/` | Fresh install of the mgmt-plane with Pod Identity | Prereq. This profile requires a working mgmt-plane. |

## Field-experience gotchas (the "why is it built this way" section)

### 1. EFS as an Add-Manifest layer, not a second CSI pack

Palette allows exactly **one pack per core layer**, and both `csi-aws-ebs` and
`csi-aws-efs` self-declare `layer=csi`. If you add both as packs, the second
one sticks in `WaitingForOtherLayers` forever — EBS installs cleanly, EFS
never does. The `spectrocloud_pack` provider block has no layer override.

Workaround (in `host-cluster-profile.tf`): add the EFS driver as a
`type="manifest"` addon layer using `storage-layer-efs-csi-manifest.yaml`. The
manifest ships Domino's own mirrored EFS CSI images so the mgmt-plane doesn't
need the non-FIPS `us-docker.pkg.dev` egress path.

If VerteX's "allow non-FIPS packages" toggle is enabled, you can alternatively
use the `csi-aws-efs` pack via `values.yaml.tmpl` (kept in this directory as
`csi-aws-efs-values.yaml.tmpl` for reference), but the layer-collision issue
above still applies — you'd have to drop the `csi-aws-ebs` layer, which
Palette usually rejects since some CSI layer is required.

### 2. EBS CSI controller must use IRSA (or Pod Identity), not node-role

Palette-managed workload clusters reconcile the node group role's managed
policy attachments back to a declared state — the nodegroup role is tagged
with `spectro__ownerUid`, and the reconciler strips any AWS managed-policy
attachments that aren't part of Palette's declared node role. If you attach
`AmazonEBSCSIDriverPolicy` to the node role directly, it gets removed within
minutes and CSI starts failing `CreateVolume` calls silently.

Fix (baked into `csi-aws-ebs-values.yaml.tmpl` in this directory): annotate
the `ebs-csi-controller-sa` SA with `eks.amazonaws.com/role-arn`. This is
reconcile-proof because the annotation is a chart value that Palette itself
re-applies. The workload cluster must have IRSA working (its OIDC provider
must be registered in IAM).

Same pattern applies to the EFS CSI controller — see `efs_csi_irsa_role_arn`
variable.

### 3. EFS mount targets are single-VPC

Silent trap: if the cluster provisions into a *new dynamic VPC*, the EFS
filesystem you pre-created in your existing "shared" VPC has no mount
targets in the new VPC and every PVC just sits Pending forever. There's no
error until the pod events show `dial tcp <efs-ip>:2049: i/o timeout`.

Fix: use static VPC placement (the profile is written for this) OR create
new mount targets in the dynamic VPC *after* provisioning, before Domino
starts trying to bind PVCs.

### 4. Domino's own EFS CSI vs. the pack — non-FIPS pull chain

The mirrored images in `storage-layer-efs-csi-manifest.yaml` are placeholder
paths (`<ECR_REGISTRY>/<DOMINO_PREFIX>/...`). Replace these with your
customer's ECR mirror before applying. Either sed the file at deploy time
(see the info-share README for the sed command) or extend the `replace()`
call in `host-cluster-profile.tf` to substitute the ECR path from a variable.

## How to use

Standard Terraform flow. Provider auth via API key in env, everything else in
`terraform.tfvars`:

```bash
export SPECTROCLOUD_APIKEY='<vertex-api-key>'
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# If needed, sed-substitute the ECR paths in the EFS manifest (see gotcha #4)
sed -i.bak \
  -e 's|<ECR_REGISTRY>|<account>.dkr.ecr.<region>.amazonaws.com|g' \
  -e 's|<DOMINO_PREFIX>|domino|g' \
  storage-layer-efs-csi-manifest.yaml

terraform init
terraform plan -out=domino.plan
terraform apply domino.plan
```

The profile appears in the Palette UI under **Profiles → Infrastructure**.
Attach it to an EKS cluster via `../vertex-workload/` (which handles the
profile clone + workload cluster provisioning end-to-end) or via the UI.

## Preflight — before you `terraform apply`

Run `./preflight-check.sh` (env vars documented at the top of the script).
Verifies:

1. Palette API reachable and API key works.
2. Named cloud account exists in the tenant + is aws-us-gov (or matches the
   partition variable).
3. VPC + subnets exist in the target AWS account and are in the right region.
4. EBS-CSI IRSA role exists and trusts this cluster's OIDC (once cluster
   exists — skipped pre-provisioning).
5. EC2 key pair exists in the target region.
6. EFS filesystem exists in the same VPC as the private subnets.
7. Pack versions referenced in `host-cluster-profile.tf` are actually
   present in the Palette pack registry (avoids the
   `data.spectrocloud_pack` failure that stalls the plan).

## What this profile does not solve (deliberate scope-out)

- **Domino install itself** — `ddlctl create config --preset eks` +
  `ddlctl install` is the Domino-side workflow. Documented separately in the
  workspace runbook `~/workspace/runbooks/domino-cluster-profile/`. Runs
  against the cluster this profile provisions.
- **Domino images** — these get pushed to ECR via
  `~/workspace/runbooks/domino-cluster-profile/load-domino-images-ecr.sh`
  (workspace-internal, not shipped here — has customer/environment
  specifics).
- **Phase 3 AWS prereqs** (KMS + S3 + EFS + IRSA + Athena) —
  `~/workspace/runbooks/domino-cluster-profile/phase3-aws-prereqs.sh` handles
  this in our internal workflow. Portable via env vars for PARTITION /
  REGION / PREFIX. Not shipped here because the specific IAM policy shapes
  are customer-negotiated per engagement.

## Customer-facing companion

The pack the customer actually sees:
[`info-share/palette-vertex/domino-cluster-profile/`](https://github.com/j-cuff/info-share/tree/main/palette-vertex/domino-cluster-profile) —
same files (minus this README + preflight script), plus a customer-audience
README that omits the field-experience context above. Send the customer that
link; keep this one for engineering conversations with the customer's
platform team.
