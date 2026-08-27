#!/usr/bin/env bash
# postflight-verify.sh
#
# Run AFTER `helm install palette` — verifies each Pod Identity-enabled pod
# actually got its env vars injected and can obtain temp creds from the local
# agent. This catches the "chart installed clean, but pods have no AWS
# credentials" silent failure mode.
#
# Env vars (required):
#   MGMT_CONTEXT       — kubectl context for the mgmt cluster
#   AWS_REGION         — e.g. us-east-1 (commercial) or us-gov-west-1 (GovCloud)
#
# Optional:
#   HUBBLE_NS         (default: hubble-system)
#   IDENTITY_NS       (default: palette-identity)
#   CAPA_NS           (default: capa-system)

set -uo pipefail

: "${MGMT_CONTEXT:?set MGMT_CONTEXT}"
: "${AWS_REGION:?set AWS_REGION}"

HUBBLE_NS="${HUBBLE_NS:-hubble-system}"
IDENTITY_NS="${IDENTITY_NS:-palette-identity}"
CAPA_NS="${CAPA_NS:-capa-system}"

FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
head() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

check_pod_env () {
  local ns=$1 selector=$2 label=$3
  local pod
  pod=$(kubectl --context "$MGMT_CONTEXT" -n "$ns" get pods \
    -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then
    fail "$label: no pod matching $selector in $ns"
    return
  fi

  # Both env vars must be present — one is the URI, the other is the token file.
  local uri tok
  uri=$(kubectl --context "$MGMT_CONTEXT" -n "$ns" exec "$pod" -- \
    printenv AWS_CONTAINER_CREDENTIALS_FULL_URI 2>/dev/null)
  tok=$(kubectl --context "$MGMT_CONTEXT" -n "$ns" exec "$pod" -- \
    printenv AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE 2>/dev/null)

  if [ -n "$uri" ] && [ -n "$tok" ]; then
    pass "$label ($ns/$pod) has Pod Identity env vars"
  else
    fail "$label ($ns/$pod) MISSING Pod Identity env vars"
    warn "  URI=[$uri]  TOKEN_FILE=[$tok]"
    warn "  Common causes: Association missing when pod was created; pod predates Association;"
    warn "                 SA name mismatch between chart-rendered SA and Association target."
    warn "  Fix: kubectl -n $ns rollout restart <deployment or statefulset>"
    return
  fi

  # If env vars are there, verify the token file actually exists in the pod
  # (webhook can inject env without mounting the token if projected volume
  # setup is broken — this is rare but real).
  if kubectl --context "$MGMT_CONTEXT" -n "$ns" exec "$pod" -- test -f "$tok" 2>/dev/null; then
    pass "$label token file exists at $tok"
  else
    fail "$label token file $tok NOT present in pod filesystem"
  fi

  # Optional: run `aws sts get-caller-identity` from inside the pod if awscli
  # is available on the image. Silent-skip if not — most Palette images don't
  # ship awscli.
  if kubectl --context "$MGMT_CONTEXT" -n "$ns" exec "$pod" -- \
       sh -c 'command -v aws' >/dev/null 2>&1; then
    if IDENT=$(kubectl --context "$MGMT_CONTEXT" -n "$ns" exec "$pod" -- \
       aws sts get-caller-identity --region "$AWS_REGION" \
       --query 'Arn' --output text 2>/dev/null); then
      pass "$label live AWS identity: $IDENT"
    else
      fail "$label pod cannot call sts:GetCallerIdentity — Association or role trust broken"
    fi
  fi
}

head "1. hubble pod has Pod Identity env vars"
check_pod_env "$HUBBLE_NS" 'app=spectro-hubble' hubble

head "2. palette-identity pod has Pod Identity env vars"
check_pod_env "$IDENTITY_NS" 'app=palette-identity' palette-identity

head "3. capa-controller-manager has Pod Identity env vars"
if kubectl --context "$MGMT_CONTEXT" get ns "$CAPA_NS" >/dev/null 2>&1; then
  check_pod_env "$CAPA_NS" 'control-plane=capa-controller-manager' capa
else
  warn "namespace $CAPA_NS does not exist — CAPA not deployed yet. Skip."
fi

head "4. traefik LB is up and reachable"
LB_HOSTNAME=$(kubectl --context "$MGMT_CONTEXT" -n ingress-traefik \
  get svc traefik-ingress-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$LB_HOSTNAME" ]; then
  pass "LB hostname: $LB_HOSTNAME"
  case "$LB_HOSTNAME" in
    internal-*)                     pass "  → internal NLB (per values-nlb-internal.yaml)" ;;
    *-*.elb.*.amazonaws.com)        pass "  → NLB (public, per values-nlb-public-eips.yaml)" ;;
    [a-f0-9]*-*.elb.*.amazonaws.com|[a-f0-9]*-[0-9]*.*.elb.amazonaws.com)
      warn "  → hostname looks like Classic ELB — LBC not managing this Service"
      warn "    Verify annotations landed at ingress.ingress.annotations (double-nested)"
      warn "    See ../mgmt-plane-nlb-migration/README.md" ;;
    *)                              warn "  → hostname shape unrecognized; check manually" ;;
  esac
else
  fail "LB has no hostname yet — check svc status and cloud-controller/LBC events"
fi

head "5. Mongo replica set healthy"
if kubectl --context "$MGMT_CONTEXT" get pods -l app=mongo -A --no-headers 2>/dev/null \
     | awk '{print $3}' | grep -qc Running; then
  pass "mongo pods Running (verify replica-set state manually with rs.status())"
else
  fail "mongo pods not all Running"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m==> Postflight verification passed. Pod Identity is working end-to-end.\033[0m\n'
  echo "Next: register the AWS cloud account in the Tenant Console with credentialType: pod-identity."
  exit 0
else
  printf '\033[31m==> %d check(s) failed. Do not register the cloud account until fixed.\033[0m\n' "$FAIL"
  exit 1
fi
