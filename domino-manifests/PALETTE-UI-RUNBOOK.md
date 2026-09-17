# Palette UI Runbook — Domino host cluster (the "buttons" path)

Build the Domino **host** EKS cluster entirely through the Palette UI, then let `ddlctl`/the
operator install the Domino **app**. Everything account/infra-specific is pushed into **profile
variables** so the SAME cluster profile is portable across AWS accounts and IL environments — a
junior tech changes variable *values*, never the profile.

> Companion: [PALETTE-TERRAFORM-RUNBOOK.md](PALETTE-TERRAFORM-RUNBOOK.md) does the identical thing
> via the spectrocloud provider. The two share the same variable set (mapping table at the bottom
> of the TF runbook). Deeper "why" lives in [DOMINO-EKS-INSTALL.md](DOMINO-EKS-INSTALL.md) and the
> repo `CLAUDE.md`; pack-registry/sync mechanics in [../pack-registry/REGISTRIES.md](../pack-registry/REGISTRIES.md).

---

## 0. Portability model — profile variables (do this first)

Define these on the cluster profile (**Profile → Variables**, macro syntax `{{.spectro.var.NAME}}`
resolved at deploy time). They are the ONLY things that change between accounts/IL levels. Set
`format=string`; mask nothing here (none are secrets — the API key/creds live in the cloud account).

| Variable | Example (sandbox) | What it abstracts | Referenced by |
|---|---|---|---|
| `AWS_REGION` | `us-gov-west-1` | region (IL portability) | csi-aws-efs values |
| `STORAGE_EFS_ID` | `fs-0b4c353e97ae4d0af` | the in-VPC EFS for `dominoshared` | csi-aws-efs values, EFS Add-Manifest |
| `EBS_CSI_IRSA_ROLE_ARN` | `arn:aws-us-gov:iam::<AWS_ACCOUNT_ID>:role/<cl>-ebs-csi` | reconcile-proof EBS creds | csi-aws-ebs values |
| `EFS_CSI_IRSA_ROLE_ARN` | `""` (static) or the phase3 ARN | dynamic efs-ap creds (optional) | csi-aws-efs values |

Values come from **phase 3** (`phase3-outputs.env`: `EFS_ID`, `EBS_CSI_IRSA_ROLE_ARN`,
`EFS_CSI_IRSA_ROLE_ARN`, `REGION`). Account/partition/VPC/subnets are chosen in the **cluster**
wizard (cloud account + static placement), not as profile variables.

> **Define the variables BEFORE the macros resolve.** The pack-editor variable dropdown only lists
> variables that already exist on the profile; a `{{.spectro.var.X}}` macro whose variable is
> undefined won't appear in the dropdown and won't resolve at deploy. Empty dropdown = you haven't
> added the variables yet.
>
> **API shortcut (verified 2026-07-10):** you can set all variables in one shot —
> `PUT /v1/clusterprofiles/<uid>/variables` with `{"variables":[{name,displayName,format,defaultValue,required,...}]}` → `204`.
> (`GET .../variables` to read.) **But the API will NOT edit a *published* profile's pack VALUES**
> — the single-pack `PUT /v1/clusterprofiles/<uid>/packs/<name>` returns **500** on a published
> profile (Palette expects a draft/new-version flow). So: variables via API is fine; **pack-values
> edits are a UI (or draft-publish) operation.**

---

## 1. The manifest / values collection (copy-paste artifacts)

Paste each into the matching layer of the **infra cluster profile** (cloud type = EKS). Palette
**REPLACES** pack values (no merge) — always paste the WHOLE file.

| Layer | Paste this file | Type |
|---|---|---|
| OS | `amazon-linux-eks` 1.0.0 (defaults) | pack |
| Kubernetes | `kubernetes-eks` `<ver>.x` (defaults) | pack |
| CNI | `cni-calico` 3.27.x (defaults) — Calico for NetworkPolicy (Domino req) | pack |
| CSI (block) | [csi-aws-ebs-values.yaml.tmpl](csi-aws-ebs-values.yaml.tmpl) → swap `${ebs_csi_irsa_role_arn}` for `{{.spectro.var.EBS_CSI_IRSA_ROLE_ARN}}` | pack values |
| CSI (shared/EFS) | [csi-aws-efs-values.spectrovars.yaml](csi-aws-efs-values.spectrovars.yaml) — already profile-variable-ized | pack values |
| CSI (shared, fallback) | [storage-layer-efs-csi-manifest.yaml](storage-layer-efs-csi-manifest.yaml) — Domino's own EFS driver via Add-Manifest, if you can't/won't use the pack | manifest |
| Domino operator | [domino-addon/domino-operator-manifests.yaml](domino-addon/domino-operator-manifests.yaml) | add-on manifest |
| Domino CR | [domino-addon/domino-cr-<cluster>.yaml](domino-addon/) (from `gen-domino-cr.sh`) | add-on manifest |

Two EFS options, pick one:
- **Pack (preferred):** `csi-aws-efs` pack + the spectrovars values → pack owns `efs.csi.aws.com` + `dominoshared`; Domino sets `storage_classes.shared.create=false`.
- **Add-Manifest (fallback/proven):** the `storage-layer-efs-csi-manifest.yaml` (Domino's mirrored images) → what domino-flat runs today.

---

## 2. Notes on every change we made, and why (the learnings)

**csi-aws-ebs values** ([csi-aws-ebs-values.yaml.tmpl](csi-aws-ebs-values.yaml.tmpl))
- Added a **`dominodisk`** StorageClass (gp3, encrypted, expandable, **NON-default**). Domino consumes it with `storage_classes.block.create=false` → NO duplicate Domino EBS driver (avoids the `CSIDriver "ebs.csi.aws.com" cannot be imported` collision).
- `controller.serviceAccount.annotations` → **IRSA** (`EBS_CSI_IRSA_ROLE_ARN`). Palette **reconciles managed node-role policies OFF**, so `aws iam attach-role-policy` for EBS gets reverted; IRSA on the SA is reconcile-proof. This fixes PVCs stuck `Pending` / "no EC2 IMDS role found / CreateVolume context deadline".
- Only ONE SC may be `is-default-class:true` → `spectro-storage-class` stays the default; `dominodisk` is non-default.
- **⚠️ YAML-nesting gotcha (hit on domino-efs, 2026-07-10):** the role-arn MUST be nested **under `annotations:`**. The pack default ships `annotations: {}` (empty map); if you add the role-arn as a *sibling* of `annotations` it becomes `serviceAccount.eks.amazonaws.com/role-arn`, which the chart **silently ignores** → SA gets no annotation → no IRSA → PVCs Pending, with no error. Wrong vs right:
  ```yaml
  # WRONG — role-arn is a sibling of annotations (inert, silently dropped)
  serviceAccount:
    annotations: {}
    eks.amazonaws.com/role-arn: "...role/..."
  # RIGHT — nested under annotations, macro-ized for portability
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "{{.spectro.var.EBS_CSI_IRSA_ROLE_ARN}}"
  ```
- **Per-cluster OIDC:** an IRSA role trusts ONE cluster's OIDC. Never hardcode another cluster's role (e.g. `domino-flat-ebs-csi`) here — it won't work (and if the nesting were correct it would hard-fail `AssumeRoleWithWebIdentity`). Leave `EBS_CSI_IRSA_ROLE_ARN` empty for the first provision (→ node-role fallback), then after the new cluster's OIDC exists run phase3, set the variable, and reconcile (or `kubectl annotate sa` — the proven path).

**csi-aws-efs values** ([csi-aws-efs-values.spectrovars.yaml](csi-aws-efs-values.spectrovars.yaml))
- SC renamed to **`dominoshared`** and forced `is-default-class:"false"` — the shipped pack default marks its EFS SC as the *default*, which would give you **two defaults** (with EBS) and break scheduling.
- `parameters.fileSystemId` → `{{.spectro.var.STORAGE_EFS_ID}}` — the EFS must have **mount targets in THIS cluster's VPC** (single-VPC rule); reusing domino-flat's VPC reuses its EFS mount targets.
- `controller.serviceAccount` IRSA + `regionalStsEndpoints: true` — GovCloud IRSA must hit the **regional `aws-us-gov` STS**, not global `sts.amazonaws.com`.
- Non-FIPS images (`us-docker.pkg.dev/palette-images`) → needs the **"allow non-FIPS packages"** toggle + the 4 images mirrored (imageswap).

**Domino config (fed to the CR generator)** — Palette owns these, so Domino must NOT re-install them (each was an ownership collision or a pre-flight failure we hit):
- `certificate_management.install=false` (Palette provides cert-manager)
- `metrics_server.install=false` (Palette provides it — do NOT set true; the `RoleBinding metrics-server-auth-reader cannot be imported` collision)
- `storage_classes.block.create=false`, `storage_classes.shared.create=false` + `name=dominoshared` (pack owns both CSIs)
- `release_overrides.cluster-autoscaler.installed=false` (Palette owns node scaling)

**Cluster (wizard) settings**
- **Node-pool labels** `dominodatalab.com/node-pool` on each machine pool (platform/default/default-gpu) — else Domino components sit `Pending`.
- **IMDS hop limit = 2** (pods reach IMDS) — set on the pool's launch template / advanced, or post-provision `aws ec2 modify-instance-metadata-options --http-put-response-hop-limit 2`.
- **Endpoint access** — for a VPC not peered with the mgmt VPC, set public + `0.0.0.0/0` (sandbox) or the mgmt NAT egress CIDRs; otherwise the cluster hangs after EKS ACTIVE with `OIDC ... context deadline exceeded`.

---

## 3. UI flow (order matters)

1. **Phase 3** (once per cluster): run `phase3-aws-prereqs.sh` or `phase3-terraform` → KMS/S3/EFS/IRSA; copy `EFS_ID` + the IRSA ARNs into the profile variables.
2. **Cluster profile** → New → Infra → EKS → add the 5 pack layers above, paste values, define the 4 profile variables.
3. **Add-on profile** (or same profile) → 2 manifest layers: Domino operator, Domino CR.
4. **Registries** — ensure the ECR pack registry is added with **"Contains Spectro Manifest"**; if you pushed a new pack, force a sync (see REGISTRIES.md — the daily `packsync` skips same-day).
5. **Create cluster** → pick the AWS cloud account → **Static placement** into the target VPC/subnets (reuse domino-flat's VPC to reuse its EFS mount targets) → set endpoint access → node pools with labels.
6. **DNS deltas** (`.local` rootDomain): operator `/etc/hosts` → Traefik ELB; mgmt CoreDNS `hosts` block; workload CoreDNS → mgmt ELB (phone-home). See CLAUDE.md rule 2.
7. **EFS SG**: allow the new node SG inbound **TCP 2049** at the EFS mount-target SG (silent-hang gotcha).
8. Cluster **Running** → operator reconciles the Domino CR → Domino serves (302 → Keycloak).

---

## 4. Smoke test / triage
- PVC `Pending` (block) → IRSA annotation missing on `ebs-csi-controller-sa`, or IMDS hop=1.
- `dominoshared` PVC stuck → EFS SG 2049 not open from nodes, or EFS not in this VPC.
- Two default StorageClasses → you left the EFS SC `is-default-class:true`.
- Namespace stuck `Terminating` → stale metrics APIServices + fluent-operator finalizers (see CLAUDE.md/DOMINO-EKS-INSTALL deltas).
