---
name: domino-on-palette-eks
description: Deploying Domino Data Lab 6.2.2 on top of a Palette-managed EKS cluster. Load whenever the user asks about the Domino host cluster profile, pack values for csi-aws-ebs / cni-calico / storage-layer-efs-csi, ddlctl bootstrap, offline image mirroring for Domino's ~207 images, the dominodisk / dominoshared StorageClass boundary, or install-time troubleshooting (CoreDNS phone-home patch, IRSA on ebs-csi-controller-sa, IMDSv2 hop limit, first-login Keycloak init). Assumes the manifests + supporting docs at the repo root are in scope.
---

# Domino on Palette-managed EKS — install + troubleshoot

This skill loads when a customer's Claude Code (or any AI agent following the
skill contract) is invoked in this repository. It is deliberately scoped to
what's IN this repo — the manifests, the pack values, the runbook markdowns —
and the shared design patterns behind them.

## When to load this skill

- The user asks about Domino Data Lab install on Palette-managed EKS
- The user asks about any of the YAMLs at the repo root
  (csi-aws-ebs-values.yaml.tmpl, csi-aws-efs-values.yaml.tmpl,
  storage-layer-efs-csi-manifest.yaml, coredns-phonehome-manifest.yaml,
  CLUSTER-PROFILE-TEMPLATE.yaml)
- The user hits a pattern-level gotcha: `dominodisk` PVC pending, CoreDNS
  phone-home not resolving, Palette reconciling away node-role IAM
  attachments, `storage_classes.block.create` collision, non-FIPS toggle,
  Keycloak first-login 500, IMDS hop-limit denials

## The single most important mental model

**Palette provisions and lifecycles the host EKS cluster.** Domino's own
`ddlctl` + `fleetcommand-agent` installs the Domino APPLICATION on top.
Two independent orchestrators — do not confuse their responsibilities.

Palette-side (host cluster profile):
- OS pack (amazon-linux-eks)
- Kubernetes pack (kubernetes-eks)
- CNI pack (cni-calico — required for NetworkPolicy)
- CSI pack (csi-aws-ebs — includes the `dominodisk` StorageClass)
- Optional Add-Manifest layers (EFS CSI, CoreDNS phone-home)

Domino-side (application, installed by ddlctl):
- The 207 workload container images from mirrors.domino.tech
- The Domino operator + Domino CR + Nucleus platform
- Keycloak-based auth
- Its own pre-flight validators (which will reject the cluster unless the
  Palette profile matches the storage/label expectations)

## The five landmines that WILL bite a fresh install

1. **Full-file pack values (no merge).** Palette REPLACES a pack's values
   document when you supply one — it does NOT merge. If you paste only a
   snippet (e.g. just the StorageClass definition), the pack's image, sidecar
   and controller config are wiped. Always paste the FULL values file. This
   is why the .tmpl files in this repo are large.
2. **Storage class ownership split.** Palette's csi-aws-ebs owns
   `ebs.csi.aws.com` (the driver). Domino would ALSO install
   `aws-ebs-csi-driver` by default — this is a Helm ownership collision
   (`CSIDriver ... cannot be imported`). Fix in Domino's config:
   `storage_classes.block.create: false` — Domino stops trying to install
   its own EBS driver and consumes Palette's. Pre-create the `dominodisk`
   StorageClass in the Palette pack values (already done in
   csi-aws-ebs-values.yaml.tmpl). The symmetric EFS decision is documented
   in `DOMINO-ADDON-LAYERS.md`.
3. **EBS CreateVolume denied at PVC time (looks like broken storage).**
   Root cause: Palette reconciles managed-policy attachments AWAY from the
   nodegroup role (spectro__ownerUid-tagged). Also, IMDSv2 hop-limit default
   is 1 — Pods can't reach IMDS to source node-role creds. Fix: IRSA on
   `ebs-csi-controller-sa` (annotation in the pack values, reconcile-proof)
   + set IMDS hop-limit to 2 on the nodegroup. See the
   `charts.aws-ebs-csi-driver.controller.serviceAccount.annotations` block
   in csi-aws-ebs-values.yaml.tmpl.
4. **CoreDNS phone-home.** If the Palette rootDomain is a fake `.local` or
   is intercepted by a CASB (Netskope / Zscaler / Prisma / Cisco Umbrella /
   BlueCoat / Forcepoint / Menlo), the workload cluster's coredns can't
   resolve the mgmt-plane hostname → cluster-management-agent can't phone
   home → cluster stuck at "phone home." coredns-phonehome-manifest.yaml is
   the Add-Manifest layer that inserts a `hosts { }` block into the Corefile
   at bring-up. Skip only when public DNS to the mgmt plane works AND no
   CASB intercepts it.
5. **First-login 500 in Domino UI.** The seeded admin creation only writes
   CentralConfig/HardwareTiers, NOT a Domino user. Create one via Keycloak
   admin console (`https://<host>/auth/`, secret name `keycloak-http`, user
   `keycloak`) → DominoRealm → Users. **The user MUST have email +
   `Email verified: on` + first/last name** — a null email causes a
   `NullPointerException` in the `UserPersister.findByEmail` path on first
   real login.

## Files in this repo and how they compose

| File | Role |
|---|---|
| `START-HERE.md` | Entry point + placeholder legend |
| `CLUSTER-PROFILE-TEMPLATE.yaml` | The Palette cluster profile shell — paste each `values:` block from the .yaml.tmpl files below |
| `csi-aws-ebs-values.yaml.tmpl` | Full csi-aws-ebs pack values with `dominodisk` SC + IRSA annotation |
| `csi-aws-efs-values.yaml.tmpl` | Optional: EFS CSI pack values (only if EFS is a pack in your registry) |
| `csi-aws-ebs-values.spectrovars.yaml` / `csi-aws-efs-values.spectrovars.yaml` | Palette UI variable-form definitions — paste into Pack Variables tab if you want the `<PLACEHOLDER>` tokens to be editable Palette variables |
| `storage-layer-efs-csi-manifest.yaml` | Domino's own EFS CSI + `dominoshared` SC as an Add-Manifest layer (the alternative to the csi-aws-efs pack) |
| `coredns-phonehome-manifest.yaml` | The Corefile patcher Job (Add-Manifest, conditional) |
| `PALETTE-UI-RUNBOOK.md` | The click-through — the ordered install sequence |
| `PROFILE-VARIABLES.md` | Reference for every variable exposed by the profile |
| `REQUIREMENTS.md` | Preflight (AWS account, IAM, VPC, ECR, tools) |
| `DOMINO-ADDON-LAYERS.md` | Architecture deep-dive — Palette-pack vs Domino-agent ownership boundaries |
| `OFFLINE-IMAGES-DDLCTL.md` | Airgap image mirroring — Domino's 207 images to your ECR |

## Substitute these placeholders before applying anything

Every occurrence of `<...>` needs a real value:

| Placeholder | What it is |
|---|---|
| `<AWS_ACCOUNT_ID>` | Your AWS account number (12 digits) |
| `<ECR_PREFIX>` | Your chosen ECR namespace where Domino images will be mirrored |
| `<PALETTE_HOST>` | Your Palette mgmt-plane rootDomain (e.g. `palette.mycompany.com`) |
| `<PALETTE_TENANT>` | Your Palette tenant identifier (only used if you have multi-tenant Palette) |
| `<VPC_ID>` | The target VPC for the Domino cluster |
| `<SUBNET_*>` | Private subnets in that VPC, one per AZ |
| `<K8S_VERSION>` | The Kubernetes minor for the pack (e.g. `1.30`) |
| `<PACK_REGISTRY>` | Your Palette pack registry name (System Console → Registries) |
| `<EFS_ID>` | Your EFS file system ID (only if you're using the EFS storage layer) |

A quick `sed` across the repo with your values hydrates every YAML.

## Non-obvious rules the customer's install team should know

- **Palette-managed EKS removes `eks-pod-identity-agent` if you install it
  out-of-band.** Palette's cluster-management-agent reconciles the cluster
  back to declared state and kills the DaemonSet + deletes the addon within
  ~4 min. Use IRSA (pod-identity-webhook is pre-installed) OR add
  `eks-pod-identity-agent` to your cluster profile.
- **helm v3, not v4.** Domino platform-operator is a v3-era chart; v4 hangs
  on `before-hook-creation` delete-waits.
- **The 207 Domino image tarballs are gzip docker-save.** Domino's stock
  `domino-load-images.py` uses `docker load|push` (needs the Docker daemon
  and doesn't pre-create ECR repos). If you have crane, a per-image push
  script is faster and more airgap-friendly. See OFFLINE-IMAGES-DDLCTL.md.

## What this skill deliberately does NOT cover

- Terraform for Palette cluster profiles (`spectrocloud_cluster_profile`
  resource, `phase3-terraform/` modules) — this repo is manifest+UI-driven.
  Ask your Spectro SE if you want the code-driven path.
- Sustaining escalation content or version-specific patches to the Palette
  mgmt plane — those live behind Spectro's internal runbook set.
- Domino's own product installation beyond the ddlctl bootstrap step —
  refer to Domino's official docs for post-install (backup, upgrade, HA).

## Support

If you hit something the deltas here don't cover, open a ticket with your
Spectro SE. Tell them the exact section of DOMINO-ADDON-LAYERS.md or
PALETTE-UI-RUNBOOK.md where you got stuck — that's usually enough to route.
