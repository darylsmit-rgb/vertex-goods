# Domino as Palette add-on layers (declarative install + upgrade)

Make Domino part of the cluster profile so Palette installs it declaratively — no `ddlctl create domino`
at install time, no static-manifest fork of the whole app, no ddlctl-in-a-container.

## Why this shape (the reasoning, short)
Domino is already an **operator + CR** architecture. So we add two layers and let the operator do the work:
| Layer (order) | Artifact | Lifecycled by |
|---|---|---|
| 1 · `domino-operator` | `domino-addon/domino-operator-manifests.yaml` — the platform-operator (rendered chart 0.6.0) **+ the Domino/HelmRelease CRDs** | Palette (Add-Manifest) |
| 2 · `domino-cr` | `domino-addon/domino-cr.yaml` — the **Domino custom resource** (embeds the config) | Palette applies it; the **operator** reconciles it → runs the fleetcommand-agent job → installs Domino |

Static manifests are correct for the **operator** (a simple, stateless controller) but would be WRONG for
the Domino *app* (40+ ordered Helm releases, generated secrets, DB-seeding Jobs). We never extract those —
the operator/agent owns them, exactly as with `ddlctl`. This is the **same supported install path**, just
triggered by Palette. TF: `domino-addon-profile.tf`.

## Prerequisites (once per environment)
1. **Host profile applied + cluster Running** (OS/k8s/CNI + `csi-aws-ebs` w/ `dominodisk` — see the v2 profile).
2. **Phase 3 AWS prereqs** done (KMS/S3/EFS/IRSA) and the **config baked into `domino-cr.yaml`** (hostname,
   buckets, IRSA ARNs, `storage_classes.block.create=false`, `metrics_server`/`certificate_management`
   `install=false`).
3. **Images mirrored to ECR** — the fleetcommand-agent + Domino's ~207 images (`load-domino-images-ecr.sh`)
   AND the platform-operator image. Get the exact list for a version: `ddlctl images --agent-version <tag>`.
4. **Non-FIPS toggle ON** (Tenant → Platform Settings) — operator + Domino images are non-FIPS and a Palette
   add-on layer IS subject to the FIPS check (ddlctl bypassed it).
5. **Node-pool labels** (`dominodatalab.com/node-pool`) + **IMDS hop limit 2** on the machine pool.

---

## ▶ Customer steps (share these)
**A. Build the add-on profile**
- *UI:* Profiles → Add Cluster Profile → type **Add-on**, cloud EKS. Add layer **Add Manifest** →
  paste `domino-operator-manifests.yaml` (name `domino-operator`). Add a second **Add Manifest** →
  paste `domino-cr.yaml` (name `domino-cr`). Keep **domino-operator ABOVE domino-cr** (applied first).
  Save & publish.
- *Terraform:* `domino-addon-profile.tf` already defines both layers via `file()` — `terraform apply`.

**B. Attach it to the host cluster** (alongside the infra profile)
- *UI:* Cluster → Profile → Add the `domino-platform` add-on profile → Save → cluster reconciles.
- *Terraform:* add a second `cluster_profile { id = spectrocloud_cluster_profile.domino_addon.id }` to the
  cluster resource.

**C. Watch it install**
```
kubectl -n domino-operator get domino          # CR → operator runs the fleetcommand-agent job
kubectl -n domino-platform get pods            # ~85 pods come up over ~30-40 min
```
If the very first reconcile logs `no matches for kind "Domino"`, that's the CRD-establish race (below) —
Palette's next reconcile pass applies the CR cleanly.

**D. First login** (unchanged): Keycloak admin console `https://<host>/auth/` (secret `keycloak-http`, user
`keycloak`); create your Domino user in **DominoRealm WITH email + email-verified**.

---

## ⬆ Upgrade workflow (think of it as: mirror → bump CR → new profile version → roll out)
A Domino upgrade (e.g. 6.2.2 → 6.3.x) is a **new catalog tag + new image set**, driven by the operator.
Declaratively:

1. **Mirror the new version's images first** (nothing installs airgap otherwise):
   `ddlctl images --agent-version <NEW.catalog-xxxx> --server <ECR> --prefix <ECR_PREFIX>` → feed the list
   to `load-domino-images-ecr.sh`. Include the new **fleetcommand-agent** image.
2. **If the platform-operator version changed** (new CRD schema/controller), update **Layer 1** first:
   re-render the new operator chart → new `domino-operator-manifests.yaml`, mirror the new operator image.
   Operator/CRD upgrades land before the CR that uses them.
3. **Bump the CR** (`domino-addon/domino-cr.yaml`): `spec.agent.version` = new catalog tag, `spec.version`
   = new Domino version. (Config edits — GPU, storage, etc. — are ALSO just CR edits here.)
4. **Publish a NEW VERSION of the add-on profile** (Palette profiles are versioned) with the bumped CR.
5. **Roll it out**: update the cluster to the new profile version → Palette applies the changed CR → the
   operator runs the fleetcommand-agent in **upgrade** mode → helm-upgrades every Domino release in order.
   Watch `kubectl -n domino-operator get domino` (JOBTYPE `upgrade`) + `ddlctl logs` for progress.
6. **Verify** the platform is healthy; run a smoke test (login, launch a workspace).

**Why this is nice:** upgrades are an auditable **diff to one CR** promoted through **profile versions** —
GitOps-friendly, and Palette tracks/rolls the change. Config drift and version are visible in the profile.

**Rollback — read this:** Palette can revert the cluster to the **prior profile version** (re-applies the
old CR), but **Domino upgrades run DB/schema migrations that are generally NOT backward-compatible** — so a
profile-version rollback does NOT guarantee a working downgrade. This is a Domino property, not a Palette
one. **Before any upgrade: back up** (DB snapshots / the `backups` S3 bucket) and test the version in a
lower environment. Treat the profile-version revert as "re-apply the old spec," not "undo the data
migration." (Same spirit as the mgmt-plane `palette-upgrade-workflow` immutable-job caution.)

**Host/infra upgrades** (k8s minor, CSI, CNI) are a **separate** track on the *host* profile, Palette-managed,
done independently — check Domino's k8s-version support matrix before bumping.

---

## Verify & troubleshoot the install (commands)
Set `KC=<path to the target cluster kubeconfig>` (e.g. `aws eks update-kubeconfig --name <cluster> --kubeconfig $KC`).

```bash
# 1. CR + agent job (is the operator reconciling the CR? JOBTYPE install/upgrade)
kubectl --kubeconfig $KC -n domino-operator get domino
kubectl --kubeconfig $KC -n domino-operator get jobs,pods | grep -v manager
POD=$(kubectl --kubeconfig $KC -n domino-operator get pods --sort-by=.metadata.creationTimestamp -o name | grep -v manager | tail -1)
kubectl --kubeconfig $KC -n domino-operator logs "$POD" -c fleetcommand-agent --tail=20   # install progress / ValueErrors

# 2. platform pods + PVC binding (PVCs Pending => EBS creds problem, see #4)
kubectl --kubeconfig $KC -n domino-platform get pods --no-headers | awk '{print $3}' | sort | uniq -c
kubectl --kubeconfig $KC -n domino-platform get pvc --no-headers | awk '{print $2}' | sort | uniq -c

# 3. node-pool labels present? (operator/agent/all Domino pods select dominodatalab.com/node-pool)
kubectl --kubeconfig $KC get nodes -L dominodatalab.com/node-pool     # machine-pool label; slow to hit existing nodes on EKS

# 4. PVCs stuck? check the EBS-CSI creds chain:
kubectl --kubeconfig $KC -n domino-platform describe pvc <name> | grep -A2 ProvisioningFailed   # "no EC2 IMDS role found" => creds
kubectl --kubeconfig $KC -n kube-system get sa ebs-csi-controller-sa -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'  # IRSA set?
aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=<cluster>" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].MetadataOptions.HttpPutResponseHopLimit' --output text   # want 2 (pod->IMDS)

# 5. phone-home DNS (agent can't reach the .local rootDomain => "no such host"; real DNS avoids this)
kubectl --kubeconfig $KC -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -A3 hosts
kubectl --kubeconfig $KC -n <cluster-uid-ns> logs -l control-plane=cluster-management-agent --tail=10 | grep 'no such host'

# 6. front door + first login
kubectl --kubeconfig $KC -n domino-platform get svc nginx-ingress-controller   # EXTERNAL-IP = the ELB
kubectl --kubeconfig $KC -n domino-platform get secret keycloak-http -o jsonpath='{.data.password}' | base64 -d   # user "keycloak", https://<host>/auth/
```

### Fixing PVCs Pending (`no EC2 IMDS role found`) — two ways
The EBS CSI controller has no AWS creds. Pick one (IRSA is the durable/declarative one):
- **IRSA (preferred, reconcile-proof):** set `EBS_CSI_IRSA_ROLE_ARN` in the `csi-aws-ebs` pack values →
  `controller.serviceAccount.annotations.eks.amazonaws.com/role-arn` = the phase-3 `<cluster>-ebs-csi` role,
  reconcile the layer, then `kubectl -n kube-system rollout restart deploy ebs-csi-controller`.
- **Node role (quick sandbox):** IMDS **hop limit → 2** (`aws ec2 modify-instance-metadata-options
  --http-put-response-hop-limit 2`) + attach an **INLINE** EBS policy to the nodegroup role (inline survives
  Palette's managed-policy reconcile), then restart the controller.

## Clean-install gotchas (learned on domino-flat, 2026-07-08)
- **IRSA works on this GovCloud cluster** — annotating `ebs-csi-controller-sa` with the phase-3
  `<cluster>-ebs-csi` role + restarting the controller injected `AWS_ROLE_ARN` (the OIDC webhook is
  functional) and PVCs bound. IRSA is a *different* mechanism than the broken EKS Pod-Identity addon —
  prefer it. Verify with the step-2 `AWS_ROLE_ARN` check above.
- **Profile edit ≠ helm release.** A `csi-aws-ebs` values edit can *show in the profile* yet the running
  **helm release stays at the old revision** with `serviceAccount.annotations: {}` — so the SA never gets
  annotated. Check `helm -n kube-system get values <release> | grep -A2 serviceAccount` and the helm
  **revision**; if it hasn't bumped, the cluster hasn't reconciled the layer (roll the cluster to the new
  profile version / edit on the cluster). Direct `kubectl annotate` is the immediate unblock (a later
  correct reconcile reinforces it; an *incorrect* one reverts it — so make the profile edit actually land).
- **Install job exhausts retries if PVCs are Pending during its attempts** (CR `retryLimit`, default 1) →
  `JobFailedExceededBackoff`. After fixing storage/creds, RE-RUN it: bump `spec.agent.spec.retryLimit`
  (`kubectl patch domino …`) or `ddlctl reconcile domino`; the operator spawns a fresh job.
- **`metrics_server.install` — default `false`, and `MissingEndpoints` does NOT mean "absent".** Palette
  ships a metrics-server (its helm release lives in the `cluster-<uid>` ns and owns kube-system objects like
  the `metrics-server-auth-reader` RoleBinding). If that pod is unhealthy you'll see
  `v1beta1.metrics.k8s.io … MissingEndpoints` — but the release is still THERE, so setting
  `metrics_server.install=true` makes Domino try to install its own and **collides** (`RoleBinding … cannot
  be imported … release-namespace must equal "domino-platform"`). ⇒ Keep **`false`** whenever a Palette
  metrics-server release exists (the normal case). A degraded metrics-server is a *separate* fix (mirror its
  image so the pod runs) — not a reason to flip `install` to true. Only set `true` on a genuinely bare
  cluster with NO metrics-server release at all (rare).
- **Who deploys a component → where you fix it.** `kubectl get <obj> -o jsonpath='{.metadata.labels.helm\.sh/chart}'`
  + its namespace: a **`-rN`** chart suffix in `domino-platform/compute/system` = **Domino** (fix in the config /
  `release_overrides`); a stock pack in `kube-system` = **Palette** (fix in the profile pack values).
- **cluster-autoscaler is Domino-deployed & redundant on Palette** (release `cluster-autoscaler`, chart
  `…-r13`, ns `domino-platform`). It crashloops (no creds) and finds no ASGs to manage. **Disable it via the
  Domino config** — VERIFIED key `release_overrides.cluster-autoscaler.installed: false` (`Release.installed`
  in `domino_config.types`; NOT `deploy`/`enabled`). `patch-config.sh` now sets this. Same `release_overrides.<release>.installed:false`
  pattern disables any other Domino release you don't want.

## ⚠️ Apply the CORRECT per-cluster CR on the FIRST install (dominoshared static-PV trap)
`dominoshared` PVs are **static** — the agent creates them from `storage_classes.shared.efs` in the CR
config, and they're **`Retain`** + **immutable**. If you install even once with a *wrong-EFS* config (e.g.
another cluster's CR, like domino-trysomething's `fs-03f…` on domino-flat), those PVs get baked with the
wrong EFS. Correcting the CR afterward does **NOT** fix them → RWX consumers (keycloak, etc.) hang forever
on `MountVolume.SetUp … the file system mount target ip address cannot be found` (that EFS has no mount
targets in this cluster's VPC).
- **Prevention:** run `gen-domino-cr.sh` for the target cluster and apply THAT CR on the first `ddlctl
  create`/reconcile — never a template still carrying another cluster's EFS/IRSA.
- **Recovery (if already polluted):** delete the stale `domino-shared-store` PVCs (both `domino-platform`
  and `domino-compute`) + their PVs — they're `Retain`, so the referenced EFS/access-point is **untouched**
  (verify reclaimPolicy first; clear stuck finalizers with `kubectl patch … -p '{"metadata":{"finalizers":null}}'`).
  Then force a **fresh** agent job (delete the running job / bump `spec.agent.spec.retryLimit`) so
  create-shared-storage recreates them with the correct EFS. **Do NOT delete the PVC while the agent is
  mid-wait** — its poll 404s and the job fails; delete on a clean slate, then run.

## Clean reinstall (wipe Domino app state, keep cluster/profile/operator)
When a churned install needs a fresh app state (stale DB creds, EFS pollution): stop the install jobs
(`kubectl -n domino-operator delete job --all`), then **delete the 3 stateful namespaces**
`domino-platform domino-compute domino-system` (keep `domino-operator` + the CRD). dominodisk PVs
(`Delete`) drop their EBS volumes; dominoshared PVs (`Retain`) go `Released` → **delete those PV objects
too** (the EFS filesystem is untouched). Then re-apply the corrected CR (update the manifest layer) → the
operator reinstalls fresh into clean namespaces → clean DBs match fresh secrets (fixes the keycloak
`invalid_grant` 401). The `kube-system` EBS-CSI SA annotation survives (namespaces don't touch it), so IRSA
keeps working.
- **Namespaces stuck `Terminating`?** Two common blockers: (1) **stale metrics APIServices** with no
  backend (`v1beta1.metrics.k8s.io` / `v1beta1.external.metrics.k8s.io` = MissingEndpoints) cause
  `NamespaceDeletionDiscoveryFailure` cluster-wide → `kubectl delete apiservice v1beta1.metrics.k8s.io
  v1beta1.external.metrics.k8s.io`. (2) **fluent-operator CRs** (`fluentbit`/`fluentd`) hold finalizers →
  `kubectl -n <ns> patch fluentbit/fluentd <name> --type merge -p '{"metadata":{"finalizers":null}}'`.

## Caveats
- **CRD-establish race** (layer ordering): raw-manifest layers have no cross-layer health gate; the operator
  layer must sit below the CR layer, and the first reconcile may need one retry pass. For strict ordering,
  split the CRDs into their own lowest layer or gate with a small wait — but reconcile-retry converges.
- **Non-FIPS toggle** must stay ON for these layers.
- **Registry creds**: the committed CR has the token scrubbed. Same-account ECR pulls via the node role
  (ECR-read) — no secret needed. Private/cross-account → add a pull-secret manifest layer + reference it.
- **Day-2**: `ddlctl diff/logs/get` still work for observability even though install/upgrade are declarative.

## CoreDNS phone-home layer (for tenant clusters with `.local` rootDomain or CASB in the path)

The Palette mgmt-plane's `cluster-management-agent` (CMA), running in every Domino tenant cluster's
`cluster-<uid>` namespace, phones home to `https://<sc_host>/v1/auth/certs` on startup and periodically
thereafter (heartbeat, node status, pack pull, gRPC config fetch). Two environmental conditions break
that call and leave the tenant cluster stuck at `no such host` or `TextConsumer` errors:

1. **Fake `.local` rootDomain** (our sandbox pattern): `sc_host = <PALETTE_HOST>`.
   Public DNS doesn't resolve `.local`. CMA gets `no such host`. Referenced in the debug-guide grep on
   line 113 above.
2. **CASB / SASE / SSL-inspection layer in the network path** (Netskope, Zscaler, Palo Alto Prisma
   Access, Cisco Umbrella, iBoss, etc.): DNS resolves fine, but the CASB intercepts the TLS handshake
   and injects a redirect (HTTP 303) or block-page body. CMA sees non-JSON, `V1AuthCertsGet` fails
   through `TextConsumer`, agent crash-loops or times out.

**Both are fixed the same way**: override CoreDNS on the tenant cluster to resolve the mgmt-plane
`rootDomain` to an IP the tenant cluster CAN route to cleanly — the mgmt-plane's public Traefik ELB
IP if there's no CASB in the path, OR a private routable IP if the tenant VPC has a peered path to
the mgmt-plane. Traffic then stays on whichever network path the operator intends, no CASB
interception, no `.local` NXDOMAIN.

### How it plugs into the profile

- File: `coredns-phonehome-manifest.yaml` (this folder). Contains a ConfigMap (target IP + hostnames),
  ServiceAccount, RBAC, and an idempotent Job that patches `kube-system/coredns` Corefile with a
  sentinel-bracketed `hosts { }` block, then rolls CoreDNS.
- TF wiring: `host-cluster-profile.tf` now has a `dynamic "pack"` block that ONLY emits this manifest
  layer when `var.mgmt_elb_ip != ""`. Empty value ⇒ layer skipped entirely, profile unchanged (matches
  production installs with real DNS + no CASB in the path).
- Placeholder substitution: two Palette-style profile variable placeholders (`MGMT_ROOTDOMAIN`,
  `MGMT_ELB_IP`) in the YAML file are replaced by Terraform via `replace()` at `terraform apply` time —
  same pattern the EFS layer uses for `STORAGE_EFS_ID`. Palette never sees the placeholders.

### When to set `mgmt_elb_ip` in `terraform.tfvars`

* **ON** — sandbox (any `.local` rootDomain), or any customer environment where a CASB / SSL-
  inspection layer sits in the network path between the tenant cluster's pods and the mgmt-plane
  hostname. Set to the mgmt-plane's Traefik ELB IP (public), OR the peered private IP if you have
  VPC peering / Transit Gateway routing tenant → mgmt.
* **OFF** — production install with a real DNS name for the mgmt-plane AND no CASB in the tenant
  cluster's egress path to it. Leave `mgmt_elb_ip = ""` (the default). The profile emits nothing for
  this layer.

### Getting the current ELB IP

```bash
kubectl --context <mgmt-plane> -n <ingress-ns> get svc <traefik-svc> \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | xargs dig +short | head -1
# On our sandbox today (palette-sandbox-135): dig aae8f3435582f4e9b9c4313a031d379a-...elb.amazonaws.com
#   → 56.136.215.158 (rotates — see caveats below)
```

Copy that IP into `terraform.tfvars`:

```
mgmt_elb_ip     = "56.136.215.158"
mgmt_rootdomain = ""    # defaults to sc_host — usually correct
```

Run `terraform apply` for the host-cluster-profile module; Palette re-applies the manifest layer on
next cluster reconcile.

### ⚠️ ELB IP rotation caveat (CLAUDE.md Rule 2)

AWS Classic ELB IPs rotate. When the mgmt-plane's Traefik ELB rotates, existing tenant clusters keep
pointing at the old IP and CMA phone-home breaks silently. Three durability options in order of
preference:

1. **Stable NAT EIP / Route53 alias for the mgmt-plane** — recommended for real production installs.
   The ELB DNS name is stable; only the IPs behind it rotate. If you can put a Route53 alias record
   or a fixed EIP in front (via NLB static IP annotation or a Global Accelerator), the tenant-side
   `mgmt_elb_ip` never needs to change.
2. **Re-apply the profile on rotation** — good enough for sandbox. Detect via a periodic check
   (`dig` the ELB, compare against `mgmt_elb_ip` in `tfvars`) and `terraform apply` when they diverge.
3. **On-cluster refresh Job** — an enhancement to the manifest that polls the ELB DNS name inside the
   tenant cluster and re-patches CoreDNS on change. Not implemented today; would eliminate the manual
   re-apply. Track as an enhancement if this pain lands on real customer engagements.

### Related product/docs gap

Tracked at **[SUS-1958](https://spectrocloud.atlassian.net/browse/SUS-1958)** — the underlying chart-side
gap (`hubble-info.apiEndpoint` is not overridable in the mgmt-plane helm chart, so `rootDomain`
propagates verbatim to every tenant cluster). Sustaining has characterized the chart-side fix as
architectural, not near-term. Until that lands, this tenant-side manifest layer is the field-proven
answer. See `runbooks/mgmt-plane-connectivity-diagnostic/` for the broader 3-mode diagnostic and the
mgmt-plane-side variant of the same fix.
