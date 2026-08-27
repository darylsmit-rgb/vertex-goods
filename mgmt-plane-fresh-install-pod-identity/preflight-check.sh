#!/usr/bin/env bash
# preflight-check.sh
#
# Run AFTER vertex-goods Stage 1-3 (Terraform + addons + IAM roles) and BEFORE
# running `helm install palette`. Verifies the Pod Identity plumbing is in
# place so the chart install doesn't come up with pods that silently have no
# AWS creds.
#
# Env vars (required):
#   MGMT_CLUSTER_NAME  — name of the EKS mgmt cluster
#   AWS_REGION         — e.g. us-east-1 (commercial) or us-gov-west-1 (GovCloud)
#   MGMT_CONTEXT       — kubectl context for the mgmt cluster
#
# Optional:
#   EXPECT_LBC=1       — also verify aws-load-balancer-controller Association
#   EXPECT_EBS_CSI=1   — also verify ebs-csi-controller-sa Association
#
# Exit codes:
#   0 = all good
#   1 = one or more checks failed (details in output)

set -uo pipefail

: "${MGMT_CLUSTER_NAME:?set MGMT_CLUSTER_NAME}"
: "${AWS_REGION:?set AWS_REGION}"
: "${MGMT_CONTEXT:?set MGMT_CONTEXT}"

FAIL=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
head() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

head "1. EKS cluster reachable"
if aws eks describe-cluster --name "$MGMT_CLUSTER_NAME" --region "$AWS_REGION" \
     --query 'cluster.status' --output text 2>/dev/null | grep -q ACTIVE; then
  pass "cluster $MGMT_CLUSTER_NAME is ACTIVE"
else
  fail "cluster $MGMT_CLUSTER_NAME is NOT ACTIVE (or aws creds wrong)"
fi

head "2. Pod Identity Agent addon healthy"
STATUS=$(aws eks describe-addon --cluster-name "$MGMT_CLUSTER_NAME" \
  --addon-name eks-pod-identity-agent --region "$AWS_REGION" \
  --query 'addon.status' --output text 2>/dev/null || echo NOTFOUND)
case "$STATUS" in
  ACTIVE)     pass "addon eks-pod-identity-agent is ACTIVE" ;;
  NOTFOUND)   fail "addon eks-pod-identity-agent is NOT installed" ;;
  *)          fail "addon eks-pod-identity-agent is in state $STATUS" ;;
esac

head "3. Pod Identity Agent DaemonSet Ready on every node"
if kubectl --context "$MGMT_CONTEXT" -n kube-system \
    rollout status ds/eks-pod-identity-agent --timeout=60s >/dev/null 2>&1; then
  DESIRED=$(kubectl --context "$MGMT_CONTEXT" -n kube-system \
    get ds eks-pod-identity-agent -o jsonpath='{.status.desiredNumberScheduled}')
  READY=$(kubectl --context "$MGMT_CONTEXT" -n kube-system \
    get ds eks-pod-identity-agent -o jsonpath='{.status.numberReady}')
  pass "DaemonSet ready ($READY/$DESIRED)"
else
  fail "DaemonSet eks-pod-identity-agent not Ready in 60s — check pods"
fi

head "4. Mgmt-plane Associations exist"
ASSOCS_JSON=$(aws eks list-pod-identity-associations \
  --cluster-name "$MGMT_CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'associations' --output json 2>/dev/null || echo '[]')

check_assoc () {
  local ns=$1 sa=$2
  if printf '%s' "$ASSOCS_JSON" | jq -e --arg ns "$ns" --arg sa "$sa" \
       '.[] | select(.namespace==$ns and .serviceAccount==$sa)' >/dev/null 2>&1; then
    pass "$ns/$sa has an Association"
  else
    fail "$ns/$sa has NO Association — chart install would come up without AWS creds"
  fi
}

check_assoc hubble-system spectro-hubble
check_assoc palette-identity palette-identity
check_assoc capa-system capa-controller-manager

[ "${EXPECT_EBS_CSI:-}" = "1" ] && check_assoc kube-system ebs-csi-controller-sa
[ "${EXPECT_LBC:-}" = "1" ]     && check_assoc kube-system aws-load-balancer-controller

head "5. StorageClass suitable for mongo PVCs exists"
SC=$(kubectl --context "$MGMT_CONTEXT" get storageclass -o json \
  | jq -r '.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true") | .metadata.name' \
  | head -1)
if [ -n "$SC" ]; then
  pass "default StorageClass: $SC"
else
  fail "no default StorageClass — set one before install (mongo PVCs will Pending forever)"
fi

head "6. No stale chart namespace / release"
if helm --kube-context "$MGMT_CONTEXT" list -A --filter '^palette$' -q 2>/dev/null | grep -q .; then
  fail "release 'palette' already exists — this is a FRESH install runbook. Delete first or use the upgrade path"
else
  pass "no existing 'palette' release; safe to install fresh"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m==> All preflight checks passed. Safe to run helm install.\033[0m\n'
  exit 0
else
  printf '\033[31m==> %d check(s) failed. Fix before installing.\033[0m\n' "$FAIL"
  exit 1
fi
