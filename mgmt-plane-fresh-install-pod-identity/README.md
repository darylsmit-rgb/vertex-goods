# Palette VerteX mgmt-plane — fresh install with EKS Pod Identity

A phased runbook for deploying `spectro-mgmt-plane` from scratch into an EKS
cluster where **every AWS API call from a Palette pod uses EKS Pod Identity**
instead of static IAM keys, an sts:AssumeRole hop, or in-tree node-role
permissions.

The IAM roles, Pod Identity Agent addon, and Associations themselves are
managed by the sibling packages in this repository:

- `../` (root) — creates `SpectroCloudPaletteRole`, `SpectroCloudHubbleRole`,
  `SpectroCloudIdentityRole`, installs the Pod Identity Agent addon on the
  mgmt cluster, and creates Associations to the two mgmt-plane SAs.
- `../vertex-workload/` — registers the AWS cloud account with
  `credentialType: pod-identity` and provisions a workload EKS cluster.
- `../workload-identities/` — configures Pod Identity on the workload cluster
  (with the caveat noted in the arch diagram).

This directory adds the **chart install** side that those pieces don't cover:
the values overlay, the phased order that ties Terraform ↔ chart install
together, and verification scripts.

## Related documents in this directory

| File | Read when |
|---|---|
| `arch-diagram.md` | Building the customer arch diagram, or explaining the auth chain to their security team |
| `component-inventory.md` | Enumerating every AWS-facing component + its expected auth mechanism |
| `values-pod-identity.yaml.tmpl` | Preparing the chart install |
| `preflight-check.sh` | After Terraform Stage 1, before running helm install — confirms Pod Identity plumbing is in place |
| `postflight-verify.sh` | After helm install — confirms each pod actually got Pod Identity env vars and can call AWS |

## Phased order (put this order in front of the customer)

The order matters. Each phase depends on the previous phase's outputs.

### Phase 0 — Prereqs (before anything)

Have these ready. If any are unknown, we can't start.

- [ ] AWS account + region confirmed. Partition (`aws` or `aws-us-gov`) matches
      the VerteX build.
- [ ] IAM permissions on the operator identity: `iam:*`, `eks:*`, `ec2:*` (at
      least Describe + Create for the resources CAPA will manage).
- [ ] VPC + subnets identified for the mgmt cluster. **Not** a workload VPC —
      this VPC hosts the mgmt cluster itself.
- [ ] EKS control plane version chosen. Note the `spectro-mgmt-plane` chart
      version's tested K8s versions before pinning.
- [ ] Chart tarball (`spectro-mgmt-plane-<VERSION>.tgz`) obtained and mirrored
      into the customer's ECR if airgap.
- [ ] `ociImageRegistry` values (endpoint, username, password, baseContentPath)
      confirmed for the customer's ECR mirror. **Chart components (specman /
      configserver / imageswap) still use these — Pod Identity for ECR is
      possible but not the pattern this chart uses today.**
- [ ] Helm v3 in operator's `$PATH`. Not v4 (CLAUDE.md rule #1).
- [ ] rootDomain chosen. DNS record ready to point at the LB once it's up.

### Phase 1 — EKS mgmt cluster (bare)

Provision the EKS cluster itself. This can be done via any tool that produces a
conformant cluster: Terraform, eksctl, CloudFormation, the customer's internal
platform. The cluster needs:

- K8s version supported by the chart
- ≥ 3 worker nodes across ≥ 2 AZs (`spectro-mgmt-plane` has mongo as a 3-replica
  StatefulSet)
- Private + public subnets (public for the LB, private for the workers)
- Node role with `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
  `AmazonEC2ContainerRegistryReadOnly` attached at minimum
- No workloads on it yet

Do **not** install cluster addons yet — the next phase does that in the order
Pod Identity requires.

Verify:

```bash
aws eks describe-cluster --name <MGMT_CLUSTER> --region <REGION> \
  --query 'cluster.status' --output text     # ACTIVE
kubectl get nodes -o wide                    # all Ready, matching AZs
```

### Phase 2 — Pod Identity addon + IAM roles

This is where `../` (the vertex-goods root Terraform) comes in.

1. Install the `eks-pod-identity-agent` managed addon on the mgmt cluster.
   The root Terraform does this, or manually:

   ```bash
   aws eks create-addon --cluster-name <MGMT_CLUSTER> --region <REGION> \
     --addon-name eks-pod-identity-agent
   ```

2. Create the three mgmt-plane IAM roles (`SpectroCloudPaletteRole`,
   `SpectroCloudHubbleRole`, `SpectroCloudIdentityRole`). Terraform in `../`
   is preferred; there's also `../create-vertex-pod-identity-roles.sh` if
   you're allergic to Terraform.

3. Verify:

   ```bash
   aws eks describe-addon --cluster-name <MGMT_CLUSTER> --region <REGION> \
     --addon-name eks-pod-identity-agent \
     --query 'addon.status' --output text     # ACTIVE

   kubectl -n kube-system rollout status ds/eks-pod-identity-agent --timeout=5m
   ```

### Phase 3 — Cluster addons (VPC CNI, EBS CSI, LBC)

Install the standard EKS addons and create Pod Identity Associations for
each.

1. **VPC CNI** — usually installed by the cluster provisioner. Confirm the
   `aws-node` DaemonSet is Ready. Optionally migrate its auth to Pod Identity
   (create a role with `AmazonEKS_CNI_Policy`, associate to
   `kube-system/aws-node`). The default node-role pattern also works; do this
   only if the customer's security posture requires no node-role AWS perms.

2. **EBS CSI** — install the addon:

   ```bash
   # Create the IAM role first (trust: pods.eks.amazonaws.com), then:
   aws eks create-addon --cluster-name <MGMT_CLUSTER> --region <REGION> \
     --addon-name aws-ebs-csi-driver

   aws eks create-pod-identity-association \
     --cluster-name <MGMT_CLUSTER> --region <REGION> \
     --namespace kube-system --service-account ebs-csi-controller-sa \
     --role-arn <EBS_CSI_ROLE_ARN>
   ```

3. **AWS Load Balancer Controller** — install via helm from the LBC chart, or
   as an addon depending on EKS version:

   ```bash
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=<MGMT_CLUSTER> \
     --set serviceAccount.create=true \
     --set serviceAccount.name=aws-load-balancer-controller

   aws eks create-pod-identity-association \
     --cluster-name <MGMT_CLUSTER> --region <REGION> \
     --namespace kube-system --service-account aws-load-balancer-controller \
     --role-arn <LBC_ROLE_ARN>

   # Bounce the controller pod so it picks up the Pod Identity env vars
   kubectl -n kube-system rollout restart deploy/aws-load-balancer-controller
   ```

4. Verify with the checklist in `preflight-check.sh`.

### Phase 4 — Chart install with Pod Identity values overlay

Now the mgmt-plane chart install itself. See `values-pod-identity.yaml.tmpl`
for the complete overlay; the parts specific to Pod Identity are the
`spectro-hubble` and `palette-identity` SA references.

```bash
helm --kube-context <MGMT> upgrade --install palette \
  <path>/spectro-mgmt-plane-<VERSION>.tgz \
  -f values-<env>.yaml \
  -f values-pod-identity.yaml.tmpl \
  --namespace default --create-namespace
```

The Association for `hubble-system/spectro-hubble` already exists (from
Phase 2 Terraform). When helm creates the pod, the Pod Identity webhook
injects the credential env vars at pod-create time. First-boot pods work
without any post-install restart because the Association predated the pod.
Same for `palette-identity/palette-identity`.

### Phase 5 — Post-install verification

Run `postflight-verify.sh` — it checks each Pod Identity SA has the
`AWS_CONTAINER_CREDENTIALS_FULL_URI` env var, each pod can obtain temp creds
from the local agent, and the first cloud-account validation call succeeds.

Verify the LB came up as an NLB (not Classic):

```bash
kubectl -n ingress-traefik get svc traefik-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
# NLB hostname:      <name>-<hash>.elb.<region>.amazonaws.com
# Classic ELB:       <32hex>-<num>.<region>.elb.amazonaws.com
```

If it's Classic, the LBC didn't pick up the Service — check the annotations
resolved to the double-nested `ingress.ingress.annotations` path (see
`../mgmt-plane-nlb-migration/README.md` for the "where does this block go"
explanation).

### Phase 6 — Cloud account registration + workload cluster smoke test

- Point DNS at the mgmt-plane LB.
- Log into the Tenant Console at the rootDomain.
- Settings → Cloud Accounts → New → AWS. **credentialType: pod-identity**.
  Enter the ARN of `SpectroCloudPaletteRole`.
- Provision a workload cluster from an existing infra profile.
- On the mgmt cluster, watch the `capa-controller-manager` logs — the AWS calls
  should succeed with STS temp creds from Pod Identity, not from a stored
  Secret.
- Once the workload cluster is Running, verify from a pod on it that
  `cluster-management-agent` is talking to the mgmt-plane cleanly.

If Phase 6 succeeds, the whole Pod Identity chain works end-to-end.

## Roles + Associations summary

For a single-glance summary of the Pod Identity plumbing after Phase 3:

```bash
aws eks list-pod-identity-associations \
  --cluster-name <MGMT_CLUSTER> --region <REGION> \
  --output table
```

Expected rows:

| Namespace | ServiceAccount | Role |
|---|---|---|
| `hubble-system` | `spectro-hubble` | `SpectroCloudHubbleRole` |
| `palette-identity` | `palette-identity` | `SpectroCloudIdentityRole` |
| `capa-system` | `capa-controller-manager` | `SpectroCloudPaletteRole` |
| `kube-system` | `ebs-csi-controller-sa` | (EBS CSI role) |
| `kube-system` | `aws-load-balancer-controller` | (LBC role) |
| `kube-system` | `aws-node` | (VPC CNI role — optional) |

## What still uses static credentials (and why)

Not everything moves to Pod Identity in a first pass. The current chart pattern
for `specman`, `configserver`, and `imageswap` continues to use ECR credentials
via `config.ociImageRegistry.username/password` chart values — this bakes a
`dockerconfigjson` Secret in the mgmt-plane namespace at install time.

This has a known 12-hour token rot problem if the credential is a short-lived
ECR token; the workaround is to use a long-lived IAM user's credentials for the
mirror, or to move these to Pod Identity in a chart-level change (which is a
separate product ask beyond this runbook).

## When to depart from this runbook

- **Air-gap environments with no working IAM OIDC or Pod Identity Agent** —
  fall back to `credentialType: secret` throughout. Static AK/SK, one IAM user
  per Palette role, standard rotation. Vertex-goods is the wrong pattern; use a
  minimal Terraform that just creates the users and stores the Secrets.
- **STS cross-account patterns** — do NOT propose on VerteX 4.9.18 aws-us-gov.
  Rule 10 / PEM-11654 blocks it install-time.
- **Highly restricted environments with no eks-auth API access** — Pod Identity
  Associations require `eks:CreatePodIdentityAssociation`. If that's not
  available, use IRSA instead (works on any EKS cluster with an OIDC provider).

## Where these documents live

- `../` — vertex-goods root (Terraform for IAM + Pod Identity addon)
- `mgmt-plane-fresh-install-pod-identity/` — this folder (chart install)
- `../mgmt-plane-nlb-migration/` — sibling folder (NLB migration for the
  mgmt-plane LB, works with or without Pod Identity)
- Customer-shareable version: **info-share** repo
  (`palette-vertex/mgmt-plane-fresh-install-pod-identity/`)
