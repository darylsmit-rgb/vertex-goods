# Cluster Profile Variables — best practices for Domino across IL environments

**Goal:** author the Domino host + add-on profiles **once** and deploy them unchanged across
IL2 → IL6 by supplying environment-specific values as **Palette cluster-profile variables**
(`{{.spectro.var.NAME}}`), resolved per-cluster at deploy time. This is the portability lever
the whole exercise is about — no per-IL profile forks.

Docs: [Cluster Profile Variables](https://docs.spectrocloud.com/profiles/cluster-profiles/create-cluster-profiles/define-profile-variables/) ·
[Create Cluster Profile Variables](https://docs.spectrocloud.com/profiles/cluster-profiles/create-cluster-profiles/define-profile-variables/create-cluster-profile-variables/)

---

## 0. Two different "variables" — don't conflate them
| Layer | What | Syntax | When resolved |
|---|---|---|---|
| **Terraform variables** (`variables.tf`) | parameterize the code that **builds** the profile/cluster | `var.k8s_version` | `terraform apply` |
| **Palette profile variables** | parameterize the profile's **pack YAML** so one profile version fits every cluster/IL | `{{.spectro.var.NAME}}` | **cluster creation** |

Use Palette profile variables for anything that differs **per cluster or per IL**. Use TF vars
for anything that differs **per profile build**. They compose: TF can create the profile *and*
seed variable definitions/defaults.

## 1. Syntax + rules (validated)
- Reference in any pack manifest: `'{{.spectro.var.VARIABLE_NAME}}'` — **wrap in single quotes**
  so the YAML schema validates. In the editor, type `{{.spectro.var.}}` to autocomplete.
- Names are prefixed automatically with `.spectro.var.`; the name you set is `VARIABLE_NAME`.
- Per variable you set: **Display name**, **Description**, **Input type** (Text · Dropdown · Multiline),
  **Data format** (string, number, boolean, version, ipv4, ipv6, cidr, …), **Default value**,
  **Required**, **Mask/Sensitive** (hides value; use for secrets), plus optional **regex/validation**.
- **Immutability:** once a profile *version* is attached to a cluster template it's immutable —
  variables are how you keep one version and still vary per cluster. Some values are effectively
  immutable **after cluster creation** (e.g. anything the OS/CNI/CSI bakes in) — treat registry,
  partition, CNI choice, storage-class names as set-once-per-cluster.
- Distinct from **system macros** (`{{.spectro.system.*}}`) which Palette fills automatically
  (cluster name, uid, cloud account, etc.) — prefer a system macro when one already exists.

## 2. Naming convention
`UPPER_SNAKE_CASE`, domain-prefixed so the builder list self-documents:
`REG_` registry · `NET_` networking · `EKS_` host cluster · `DOM_` Domino app · `SEC_` secrets.

## 3. Recommended variable catalog (host EKS profile)
| Variable | Format / Input | Default (IL4/5 GovCloud) | Req | Sensitive | Used in |
|---|---|---|---|---|---|
| `REG_ENDPOINT` | string | `<AWS_ACCOUNT_ID>.dkr.ecr.us-gov-west-1.amazonaws.com` | ✓ | — | pack image overrides / air-gap refs |
| `REG_BASE_PATH` | string | `<ECR_PREFIX>` | ✓ | — | pack content base (see REGISTRIES.md #4) |
| `AWS_PARTITION` | Dropdown `aws \| aws-us-gov \| aws-iso \| aws-iso-b` | `aws-us-gov` | ✓ | — | any ARN in pack values |
| `AWS_REGION` | Dropdown | `us-gov-west-1` | ✓ | — | CSI, LB, EFS |
| `EKS_K8S_VERSION` | version | `1.30` | ✓ | — | kubernetes-eks tag |
| `NET_CNI` | Dropdown `cni-calico \| cni-aws-vpc-eks-helm-fips` | `cni-calico` | ✓ | — | CNI layer (Domino wants NetworkPolicy → Calico) |
| `NET_CLUSTER_DOMAIN` | string | `""` (env-specific) | ✓ | — | ingress host / wildcard |
| `STORAGE_EFS_ID` | string (regex `^fs-[0-9a-f]+$`) | `""` | ✓ | — | `dominoshared` EFS SC (Domino installs its own EFS CSI) |
| `STORAGE_EBS_IRSA_ROLE_ARN` | string (`arn:…:role/…-ebs-csi`) | `""` | ✓ | — | `csi-aws-ebs` → `controller.serviceAccount.annotations` (reconcile-proof EBS creds) |
| `STORAGE_DISK_SIZE_GB` | number | `128` | — | — | platform node disk |
| `SEC_REGISTRY_CACERT` | Multiline | `""` | — | ✓ | private-registry CA (Harbor/JFrog) |

**`dominodisk` StorageClass** lives **inside the `csi-aws-ebs` pack values** (`charts.aws-ebs-csi-driver.storageClasses`),
not hand-created — see `csi-aws-ebs-values.yaml.tmpl`: gp3 + encrypted + expandable, **non-default** (keep
`spectro-storage-class` the one default; Domino names `dominodisk` explicitly). ⚠️ Palette **replaces** pack values
(no merge) → edit the FULL values, never a snippet. Pack is FIPS (`gcr.io/spectro-images-fips`) → no toggle needed.
Domino config then sets `storage_classes.block.create=false` to consume it.

## 4. Recommended variable catalog (Domino add-on profile)
| Variable | Format / Input | Default | Req | Sensitive | Used in |
|---|---|---|---|---|---|
| `DOM_VERSION` | version | (pin, e.g. `6.2.2`) | ✓ | — | Domino chart/pack tag |
| `DOM_FQDN` | string | `""` | ✓ | — | Domino hostname / TLS SAN |
| `DOM_REGISTRY` | string | `{{.spectro.var.REG_ENDPOINT}}/domino` | ✓ | — | Domino image location |
| `DOM_ENABLE_GPU` | boolean / Dropdown | `false` | — | — | GPU node pool + operator toggle |
| `DOM_PLATFORM_NAMESPACE` | string | `domino-platform` | — | — | install namespace |
| `DOM_LICENSE` | Multiline | `""` | ✓ | ✓ | Domino license |
| `SEC_DOCKER_PULL_TOKEN` | string | `""` | — | ✓ | private registry pull secret |

> Keep infra vars on the **host** profile and app vars on the **add-on** profile — matches the
> two-profile split and lets Domino app teams own their variables without touching infra.

## 5. IL portability matrix (same profile, different values)
| Variable | IL2 (commercial) | IL4 / IL5 (GovCloud) | IL6 (isolated) |
|---|---|---|---|
| `AWS_PARTITION` | `aws` | `aws-us-gov` | `aws-iso` / `aws-iso-b` |
| `AWS_REGION` | `us-east-1` | `us-gov-west-1` | region-specific |
| `REG_ENDPOINT` | commercial ECR / Harbor | GovCloud ECR | disconnected registry |
| `NET_CLUSTER_DOMAIN` | `*.dev.example.com` | `*.gov.example.com` | `*.<enclave>.local` |
| lineage/build | `palette/` (non-FIPS ok) | **`vertex/` FIPS** (exposes `awsgov`) | `vertex/` FIPS |
| exposure | public LB | internal NLB | internal-only + proxy |
> This is the "four variables" talk-track (registry · partition · connectivity/exposure ·
> lineage) made concrete as profile variables — see `runbooks/portability-talk-track/`.

## 6. Example — variable interpolation in a pack manifest
`csi-aws-efs` values (the `dominoshared` RWX SC), fully parameterized:
```yaml
storageClasses:
  - name: dominoshared
    isDefault: false
    volumeBindingMode: Immediate
    parameters:
      provisioningMode: efs-ap
      fileSystemId: '{{.spectro.var.STORAGE_EFS_ID}}'
      directoryPerms: "700"
```
ARN with partition (works in every IL):
```yaml
roleArn: 'arn:{{.spectro.var.AWS_PARTITION}}:iam::{{.spectro.system.aws.accountId}}:role/domino-node'
```

## 7. Best practices checklist
- [ ] **Default to the common IL** (GovCloud here) so most deploys need zero overrides.
- [ ] **Required + no default** only for values with no safe default (`STORAGE_EFS_ID`, `DOM_FQDN`, `NET_CLUSTER_DOMAIN`).
- [ ] **Mask every secret** (`DOM_LICENSE`, `SEC_*`) — sensitive vars are write-only in the UI.
- [ ] **Dropdown for constrained sets** (`AWS_PARTITION`, `NET_CNI`) — prevents typos that fail at deploy.
- [ ] **`version` format** for pack tags so validation catches bad values.
- [ ] **Never hardcode** registry/partition/domain/EFS in pack YAML — always a variable, so the profile version is IL-agnostic.
- [ ] Prefer a **system macro** (`{{.spectro.system.*}}`) when Palette already provides the value.
- [ ] Document each variable's owner (infra vs app) so the two profiles stay cleanly separable.

## ⚠️ Known gaps to close before a real Domino deploy
1. **`csi-aws-efs` pack is NOT in the mirror** (no in-account source has it). `dominoshared` (RWX)
   needs it — obtain from Spectro Support's pack bundle, or substitute an available RWX CSI
   (`csi-longhorn-fips` / `csi-rook-ceph-addon`). Track before building the host profile.
2. **`cni-calico 3.27.0` doesn't exist** in the mirror — available: 3.27.2 (and 3.28–3.30). Pin
   `EKS_K8S_VERSION`-compatible Calico; update `host-cluster-profile.tf` accordingly.
3. **Domino images/airgap bundle** still blocked on Domino account creds (mirrors.domino.tech).
