# Domino Data Lab on Palette-managed EKS — customer package

**Audience:** platform / infrastructure engineers deploying Domino on top of a
Palette-managed EKS cluster on AWS (commercial or GovCloud).

**What's in this folder:** the manifests, pack values, a ready-to-import
cluster-profile template, and runbooks needed to run through the deployment
via the Palette UI + `ddlctl` — the manifest / UI path only. Terraform-driven
variants exist internally at Spectro and are available on request, but they're
not included here.

**For AI-assisted implementations:** `.claude/skills/domino-on-palette-eks/`
contains a skill file that loads automatically when this repo is opened in
Claude Code. Any Claude session in this folder will pick up the design
patterns, common gotchas, and file-composition rules that would otherwise
require reading every doc.

## Read in this order

1. **[REQUIREMENTS.md](REQUIREMENTS.md)** — preflight: AWS account
   prereqs, IAM, VPC/subnet shape, ECR needs, tools on the operator
   workstation.
2. **[PALETTE-UI-RUNBOOK.md](PALETTE-UI-RUNBOOK.md)** — click-through
   for authoring the cluster profile in the Palette UI, including where to
   paste each YAML from this folder. This is the ordered install sequence.
3. **[DOMINO-ADDON-LAYERS.md](DOMINO-ADDON-LAYERS.md)** — architecture
   deep-dive: where Palette's ownership stops and Domino's begins, storage
   class boundaries (EBS vs EFS ownership split, `dominodisk` vs
   `dominoshared`), and why we set `storage_classes.block.create=false`.
4. **[PROFILE-VARIABLES.md](PROFILE-VARIABLES.md)** — reference of every
   variable exposed by the profile, what it does, and reasonable defaults.
5. **[OFFLINE-IMAGES-DDLCTL.md](OFFLINE-IMAGES-DDLCTL.md)** — airgap
   image mirroring (Domino's 207 images → your ECR) and `ddlctl bootstrap`
   quirks. Skip if you're on a connected environment.

## Cluster profile template (start here for the profile itself)

[CLUSTER-PROFILE-TEMPLATE.yaml](CLUSTER-PROFILE-TEMPLATE.yaml) is the
ready-to-import cluster-profile shell. Edit four things (`<K8S_VERSION>`,
`<PACK_REGISTRY>`, plus paste the values from the four pack-values files
below), and import via Palette UI → Cluster Profiles → Add Cluster Profile
→ Import from File. See PALETTE-UI-RUNBOOK.md for the click path.

## Manifests + pack values in this folder

| File | Where to use it |
|---|---|
| [csi-aws-ebs-values.yaml.tmpl](csi-aws-ebs-values.yaml.tmpl) | Values for the `csi-aws-ebs` Palette pack — includes the `dominodisk` StorageClass and the EBS CSI IRSA annotation. See ADDON-LAYERS for the full-file-replace rationale. |
| [csi-aws-efs-values.yaml.tmpl](csi-aws-efs-values.yaml.tmpl) | Values for the `csi-aws-efs` Palette pack, if EFS CSI is available as a pack in your registry. |
| [csi-aws-ebs-values.spectrovars.yaml](csi-aws-ebs-values.spectrovars.yaml) | Palette UI variable-form definition — paste into the pack's Variables tab so the `<AWS_ACCOUNT_ID>`/`<VPC_ID>`/etc. become editable Palette variables. |
| [csi-aws-efs-values.spectrovars.yaml](csi-aws-efs-values.spectrovars.yaml) | Same, for the EFS pack. |
| [storage-layer-efs-csi-manifest.yaml](storage-layer-efs-csi-manifest.yaml) | Domino-shipped EFS CSI as an **Add-Manifest layer** — use when the EFS CSI pack isn't in your registry. Also creates the `dominoshared` StorageClass. |
| [coredns-phonehome-manifest.yaml](coredns-phonehome-manifest.yaml) | CoreDNS override for phone-home resolution when the Palette root domain is not real DNS. |

## Substitute these placeholders before applying

Every occurrence of `<...>` needs a real value from your environment:

| Placeholder | Example real value | Where it comes from |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | `123456789012` | your AWS account number |
| `<ECR_PREFIX>` | `mycompany-domino` | your chosen ECR namespace / prefix |
| `<PALETTE_HOST>` | `palette.mycompany.local` | your Palette mgmt-plane root domain |
| `<PALETTE_TENANT>` | `palette-XYZ` (if used) | your Palette tenant identifier |
| `<VPC_ID>` | `vpc-0a1b2c3d4e5f67890` | the target VPC for the Domino cluster |
| `<SUBNET_*>` | subnet IDs | private subnets in that VPC, one per AZ |

A quick `sed` on each YAML file with your values gets you fully-hydrated
manifests ready to paste into the Palette UI.

## What this package does NOT include

- Palette cluster-profile **Terraform** (`.tf` files, `phase3-terraform/`
  module, `deploy.sh`). Available on request if you want the code-driven
  path — reach out to your Spectro SE.
- **Internal install-phase deltas / narrative** — the "master runbook with
  13 deltas" and phase-by-phase script sequence live in Spectro's internal
  runbook set; they reference our sandbox endpoints and automation. Ask
  your SE if you want to review those separately.
- Internal Spectro sustaining conversations, our own account IDs, the
  build scripts for the Palette VerteX mgmt plane.
- Domino 6.2.2 container images — those come from Domino's own registry
  (`mirrors.domino.tech`), mirrored to your ECR per
  `OFFLINE-IMAGES-DDLCTL.md`.

## Support

If you hit something the deltas in `DOMINO-EKS-INSTALL.md` don't cover,
open a ticket with your Spectro SE — we've been through most of the
install-time surprises and can point at the specific fix.
