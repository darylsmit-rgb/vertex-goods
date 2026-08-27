#!/usr/bin/env bash
# preflight-check.sh
#
# Run before `terraform apply` for the Domino cluster profile. Catches the
# things that make `terraform plan` succeed but `apply` (or the subsequent
# cluster provisioning) fail:
#   1. Palette API not reachable / API key wrong
#   2. Named cloud account doesn't exist
#   3. VPC + subnets not in the target region
#   4. EC2 key pair not in the target region
#   5. EFS filesystem not in the same VPC as the private subnets
#   6. IRSA role missing (once workload cluster exists — skipped if cluster
#      hasn't been provisioned yet)
#   7. Referenced pack versions not present in the Palette pack registry
#
# Env vars (required):
#   AWS_REGION         — e.g. us-east-1 or us-gov-west-1
#   SC_HOST            — self-hosted Palette API host (matches terraform.tfvars sc_host)
#   SC_API_KEY_FILE    — path to a file containing the Palette API key
#   AWS_CLOUD_ACCOUNT  — name of the AWS cloud account in Palette
#   VPC_ID             — VPC we'll provision the workload cluster into
#   SSH_KEY_NAME       — EC2 key pair name
#
# Optional:
#   EFS_FILE_SYSTEM_ID — pre-created EFS id
#   EBS_CSI_IRSA_ROLE  — IRSA role for ebs-csi-controller-sa
#   PARTITION          — aws | aws-us-gov | aws-iso | aws-iso-b (default aws)

set -uo pipefail

: "${AWS_REGION:?set AWS_REGION}"
: "${SC_HOST:?set SC_HOST (Palette API host)}"
: "${SC_API_KEY_FILE:?set SC_API_KEY_FILE (path to Palette API key)}"
: "${AWS_CLOUD_ACCOUNT:?set AWS_CLOUD_ACCOUNT}"
: "${VPC_ID:?set VPC_ID}"
: "${SSH_KEY_NAME:?set SSH_KEY_NAME}"

PARTITION="${PARTITION:-aws}"
FAIL=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
head() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ -f "$SC_API_KEY_FILE" ] || { echo "SC_API_KEY_FILE ($SC_API_KEY_FILE) not readable"; exit 2; }
API_KEY=$(cat "$SC_API_KEY_FILE")
CURL_OPTS=(-sk --max-time 10 -H "ApiKey: $API_KEY")

head "1. Palette API reachable + API key valid"
if curl "${CURL_OPTS[@]}" "https://${SC_HOST}/v1/users/me" -o /tmp/me -w '%{http_code}\n' 2>/dev/null | grep -q '^200$'; then
  USER=$(jq -r '.spec.emailId // .metadata.name // "unknown"' /tmp/me 2>/dev/null)
  pass "authenticated to https://${SC_HOST} as ${USER}"
else
  fail "cannot authenticate to https://${SC_HOST}"
  fail "  check SC_HOST, SC_API_KEY_FILE, and network reachability"
fi

head "2. Named cloud account exists in tenant"
if curl "${CURL_OPTS[@]}" "https://${SC_HOST}/v1/cloudaccounts/aws" -o /tmp/ca 2>/dev/null; then
  if jq -e --arg n "$AWS_CLOUD_ACCOUNT" '.items[]? | select(.metadata.name == $n)' /tmp/ca >/dev/null 2>&1; then
    pass "cloud account '$AWS_CLOUD_ACCOUNT' registered in tenant"
  else
    fail "cloud account '$AWS_CLOUD_ACCOUNT' NOT found in tenant"
    warn "  available accounts:"
    jq -r '.items[]?.metadata.name' /tmp/ca 2>/dev/null | sed 's/^/    /' | head -10
  fi
else
  warn "cannot list cloud accounts — API call failed"
fi

head "3. VPC exists in target region + partition"
if aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$VPC_ID" \
     --query 'Vpcs[0].VpcId' --output text >/dev/null 2>&1; then
  pass "VPC $VPC_ID found in $AWS_REGION"
else
  fail "VPC $VPC_ID NOT found in $AWS_REGION (or partition mismatch: expected $PARTITION)"
fi

head "4. EC2 key pair exists in target region"
if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$SSH_KEY_NAME" \
     --query 'KeyPairs[0].KeyName' --output text >/dev/null 2>&1; then
  pass "key pair '$SSH_KEY_NAME' present in $AWS_REGION"
else
  fail "key pair '$SSH_KEY_NAME' NOT found in $AWS_REGION"
  warn "  Palette will NOT create the key pair — it must exist beforehand."
  warn "  Fix: aws ec2 create-key-pair --region $AWS_REGION --key-name $SSH_KEY_NAME"
fi

head "5. EFS filesystem in the same VPC (if configured)"
if [ -n "${EFS_FILE_SYSTEM_ID:-}" ]; then
  EFS_VPC=$(aws efs describe-mount-targets --region "$AWS_REGION" \
    --file-system-id "$EFS_FILE_SYSTEM_ID" \
    --query 'MountTargets[0].VpcId' --output text 2>/dev/null || echo "")
  if [ -z "$EFS_VPC" ] || [ "$EFS_VPC" = "None" ]; then
    fail "EFS $EFS_FILE_SYSTEM_ID has NO mount targets — PVCs will Pending forever"
    warn "  Fix: aws efs create-mount-target --file-system-id $EFS_FILE_SYSTEM_ID ..."
  elif [ "$EFS_VPC" = "$VPC_ID" ]; then
    pass "EFS $EFS_FILE_SYSTEM_ID mount targets are in VPC $VPC_ID"
  else
    fail "EFS $EFS_FILE_SYSTEM_ID mount targets are in $EFS_VPC, NOT $VPC_ID"
    warn "  EFS mount targets are single-VPC — dominoshared PVCs will fail to mount."
  fi
else
  warn "EFS_FILE_SYSTEM_ID not set — skipping EFS check"
fi

head "6. EBS-CSI IRSA role (if configured)"
if [ -n "${EBS_CSI_IRSA_ROLE:-}" ]; then
  ROLE_NAME="${EBS_CSI_IRSA_ROLE##*/}"
  if aws iam get-role --role-name "$ROLE_NAME" \
       --query 'Role.Arn' --output text >/dev/null 2>&1; then
    pass "IAM role '$ROLE_NAME' exists"
    # Optional: verify trust policy targets ebs-csi-controller-sa (best-effort)
    aws iam get-role --role-name "$ROLE_NAME" --output json 2>/dev/null \
      | jq -e '.Role.AssumeRolePolicyDocument.Statement[]? | select(.Condition.StringEquals // {} | to_entries[]? | .value | strings | contains("ebs-csi-controller-sa"))' >/dev/null 2>&1 \
      && pass "  trust policy references ebs-csi-controller-sa" \
      || warn "  trust policy does NOT visibly reference ebs-csi-controller-sa — verify manually"
  else
    fail "IAM role '$ROLE_NAME' NOT found — CSI controller will fail to CreateVolume"
  fi
else
  warn "EBS_CSI_IRSA_ROLE not set — CSI controller will inherit whatever the SA gets"
fi

head "7. Referenced pack versions in Palette registry"
# The profile references specific pack versions in host-cluster-profile.tf.
# Verify each is actually present in the registry.
for pack in "amazon-linux-eks:1.0.0" "cni-calico:3.27.2" "csi-aws-ebs:1.30.0"; do
  name="${pack%%:*}"
  version="${pack##*:}"
  if curl "${CURL_OPTS[@]}" "https://${SC_HOST}/v1/packs?filters=metadata.name%3D${name}" \
       -o /tmp/pack 2>/dev/null; then
    if jq -e --arg v "$version" '.items[]? | select(.spec.version == $v)' /tmp/pack >/dev/null 2>&1; then
      pass "$pack present in registry"
    else
      fail "$name version $version NOT found in registry"
      warn "  available versions of $name:"
      jq -r '.items[]?.spec.version' /tmp/pack 2>/dev/null | sort -u | sed 's/^/    /' | head -8
    fi
  else
    warn "  API call failed for $pack — skipping"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m==> All preflight checks passed. Safe to run terraform apply.\033[0m\n'
  exit 0
else
  printf '\033[31m==> %d check(s) failed. Fix before applying.\033[0m\n' "$FAIL"
  exit 1
fi
