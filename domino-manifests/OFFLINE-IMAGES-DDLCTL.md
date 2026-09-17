# Domino 6.2.2 offline: load images to ECR + install ddlctl (macOS)

Refs: [offline air-gapped install](https://docs.dominodatalab.com/en/latest/admin_guide/87b601/offline-air-gapped-installation/) ·
[install ddlctl](https://docs.dominodatalab.com/en/latest/admin_guide/598b40/install-the-ddlctl-command-line/) ·
[work with ddlctl](https://docs.dominodatalab.com/en/latest/admin_guide/c3298b/work-with-the-ddlctl-command-line/)

Bundle: `~/Downloads/docker-images-6.2.2/` — **207 images / 71 GB**, `images.json` + gzip
docker-save tars + `domino-load-images.py`. Domino 6.2.2 = **fleetcommand-agent v71.3**.

## 1. Load images into ECR  (use our ECR-aware loader, not the stock .py)
`load-domino-images-ecr.sh` in this folder. Why not `domino-load-images.py`:
| Stock `domino-load-images.py` | Problem on ECR | Our loader |
|---|---|---|
| `docker load` every tar | needs Docker daemon; loads all **71 GB** into Docker Desktop disk → overflow | `crane push` (no daemon) |
| `docker push` | **ECR doesn't auto-create repos** → push fails | pre-creates all 198 repos |
| `.tar` are **gzip** docker-save | `docker load` handles gzip, but crane doesn't | gunzip to temp per-image, push, delete (peak temp ≈ one image ~8 GB, never 71 GB) |
| single 12h ECR token | 71 GB upload can outlast it | re-auths every 25 pushes |

```bash
# defaults: REGISTRY=<AWS_ACCOUNT_ID>.dkr.ecr.us-gov-west-1.amazonaws.com  PREFIX=<ECR_PREFIX>
bash runbooks/domino-cluster-profile/load-domino-images-ecr.sh
```
Idempotent/resumable (skips tags already in ECR). Lands images at
`<AWS_ACCOUNT_ID>.dkr.ecr.us-gov-west-1.amazonaws.com/<ECR_PREFIX>/domino/<name>:<tag>`.
→ so the **image-registry** value for ddlctl is `<AWS_ACCOUNT_ID>.dkr.ecr.us-gov-west-1.amazonaws.com/<ECR_PREFIX>`.

## 2. Install ddlctl (macOS Apple Silicon = arm64)
Downloads are behind `mirrors.domino.tech` **basic auth** (same creds as the image bundle).
```bash
export VERSION=71.3          # confirm on the 6.2.2 release notes; matches fleetcommand-agent v71.3
export OS=darwin ARCH=arm64  # Apple Silicon; use x86_64 on Intel Macs
curl -fSL -u "<DOMINO_USER>:<DOMINO_PASS>" \
  "https://mirrors.domino.tech/s3/domino-artifacts/ddlctl/${VERSION}/ddlctl_${VERSION}_${OS}_${ARCH}.tar.gz" \
  -o ddlctl.tar.gz
tar -xvf ddlctl.tar.gz
sudo mv ddlctl_${VERSION}_${OS}_${ARCH}/ddlctl /usr/local/bin/ && chmod +x /usr/local/bin/ddlctl
xattr -d com.apple.quarantine /usr/local/bin/ddlctl 2>/dev/null || true   # Gatekeeper
ddlctl version
```

## 3. Generate the install config pointing at ECR
`--image-registry` rewrites every image ref (originally `quay.io/domino/…`) to our mirror.
Must MATCH where step 1 pushed (`<REGISTRY>/<PREFIX>`).

> ⚠️ **`ddlctl create config --offline` runs the fleetcommand-agent from the LOCAL Docker
> daemon — it does NOT pull from the registry.** Two prereqs it doesn't spell out:
> 1. **Docker daemon must be running** (`open -a Docker`); ddlctl shells out to `docker`.
> 2. The agent image must be **loaded locally AND tagged as the `--agent-repository:--agent-version`
>    ref**, or you get `in offline mode, but <ref> is not available locally`:
> ```bash
> docker load -i domino-fleetcommand-agent-6.2.2.catalog-34a6626.tar   # loads quay.io/domino/fleetcommand-agent:...
> docker tag quay.io/domino/fleetcommand-agent:6.2.2.catalog-34a6626 \
>   <AWS_ACCOUNT_ID>.dkr.ecr.us-gov-west-1.amazonaws.com/<ECR_PREFIX>/domino/fleetcommand-agent:6.2.2.catalog-34a6626
> ```
> `--agent-version` = the **catalog tag** `6.2.2.catalog-34a6626` (NOT the image's `v71.3` tag).

```bash
ddlctl create config \
  --offline \
  --agent-version 6.2.2.catalog-34a6626 \
  --agent-repository <AWS_ACCOUNT_ID>.dkr.ecr.us-gov-west-1.amazonaws.com/<ECR_PREFIX>/domino/fleetcommand-agent \
  --image-registry <AWS_ACCOUNT_ID>.dkr.ecr.us-gov-west-1.amazonaws.com/<ECR_PREFIX> \
  > domino.yml
```
Drop `--username/--password` for generating the config — that auth is only how the *cluster*
pulls from ECR at install; on EKS the node/IRSA role already has ECR pull (see the pod-identity/
node-role notes in `runbooks/pack-registry/REGISTRIES.md`). ⚠️ if you DO pass
`--password "$(aws ecr get-login-password …)"`, it's a **12h token** — don't bake it into a
persistent imagePullSecret; rely on the node role or an ECR-token-refresh CronJob.

## 4. Still needed before a real deploy
- **Helm charts** (fleetcommand-agent chart + Domino charts) → mirror to the **OCI Helm** registry
  (`runbooks/pack-registry/REGISTRIES.md` §A). Images ≠ charts.
- **`csi-aws-efs` pack** for `dominoshared` RWX — absent from all mirrors (`PROFILE-VARIABLES.md` §gaps).
- Parameterize the Palette add-on profile with the `DOM_*` variables (`PROFILE-VARIABLES.md`).
