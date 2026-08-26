#!/usr/bin/env bash

set -Eeuo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${SCRIPT_DIR}/policies"

CLUSTER_NAME="vc-test"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
AWS_PROFILE_NAME=""
NETWORK_MODE="existing"
NAME_SUFFIX="vertex"
PALETTE_ROLE_NAME="SpectroCloudPaletteRole"
HUBBLE_ROLE_NAME="SpectroCloudHubbleRole"
IDENTITY_ROLE_NAME="SpectroCloudIdentityRole"
MANAGE_CLOUDFORMATION="true"
CREATE_ASSOCIATIONS="true"
ASSUME_YES="false"

usage() {
  cat <<'EOF'
Create the three same-account IAM roles used by Palette VerteX EKS Pod Identity.

Usage:
  create-vertex-pod-identity-roles.sh [options]

Required unless --skip-associations is used:
  --cluster-name NAME       EKS management cluster hosting Palette VerteX
  --region REGION           AWS region of the EKS management cluster

Options:
  --network-mode MODE       existing (minimum-static) or create (minimum-dynamic)
                            VPC permissions; default: existing
  --name-suffix VALUE       Suffix for customer-managed policies; default: vertex
  --palette-role NAME       Default: SpectroCloudPaletteRole
  --hubble-role NAME        Default: SpectroCloudHubbleRole
  --identity-role NAME      Default: SpectroCloudIdentityRole
  --profile PROFILE         AWS CLI named profile
  --manual-cloudformation   Do not attach permissions that let Palette manage the
                            CAPA CloudFormation stack; you must manage it yourself
  --skip-associations       Create roles and policies only
  --yes                     Do not prompt before changing AWS IAM/EKS resources
  -h, --help                Show this help

Examples:
  # Existing VPC, automatic CAPA stack management, and associations
  ./create-vertex-pod-identity-roles.sh \
    --cluster-name vertex-management \
    --region us-gov-west-1 \
    --network-mode existing \
    --name-suffix navy \
    --yes

  # Create only the IAM roles; add associations later
  ./create-vertex-pod-identity-roles.sh \
    --network-mode create \
    --skip-associations \
    --yes
EOF
}

info() {
  printf '[INFO] %s\n' "$*" >&2
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" ]] || die "${option} requires a value."
}

while (( $# > 0 )); do
  case "$1" in
    --cluster-name)
      require_value "$1" "${2:-}"
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --region)
      require_value "$1" "${2:-}"
      REGION="$2"
      shift 2
      ;;
    --network-mode)
      require_value "$1" "${2:-}"
      NETWORK_MODE="$2"
      shift 2
      ;;
    --name-suffix)
      require_value "$1" "${2:-}"
      NAME_SUFFIX="$2"
      shift 2
      ;;
    --palette-role)
      require_value "$1" "${2:-}"
      PALETTE_ROLE_NAME="$2"
      shift 2
      ;;
    --hubble-role)
      require_value "$1" "${2:-}"
      HUBBLE_ROLE_NAME="$2"
      shift 2
      ;;
    --identity-role)
      require_value "$1" "${2:-}"
      IDENTITY_ROLE_NAME="$2"
      shift 2
      ;;
    --profile)
      require_value "$1" "${2:-}"
      AWS_PROFILE_NAME="$2"
      shift 2
      ;;
    --manual-cloudformation)
      MANAGE_CLOUDFORMATION="false"
      shift
      ;;
    --skip-associations)
      CREATE_ASSOCIATIONS="false"
      shift
      ;;
    --yes)
      ASSUME_YES="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

for command_name in aws jq sed cmp mktemp; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    die "Required command not found: ${command_name}"
done

[[ "${NETWORK_MODE}" == "existing" || "${NETWORK_MODE}" == "create" ]] ||
  die "--network-mode must be 'existing' or 'create'."

for role_name in \
  "${PALETTE_ROLE_NAME}" \
  "${HUBBLE_ROLE_NAME}" \
  "${IDENTITY_ROLE_NAME}"; do
  [[ "${role_name}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] ||
    die "Invalid IAM role name: ${role_name}"
done

[[ "${NAME_SUFFIX}" =~ ^[A-Za-z0-9+=,.@_-]{1,48}$ ]] ||
  die "--name-suffix contains unsupported characters or is longer than 48 characters."

if [[ "${CREATE_ASSOCIATIONS}" == "true" ]]; then
  [[ -n "${CLUSTER_NAME}" ]] ||
    die "--cluster-name is required unless --skip-associations is used."
  [[ -n "${REGION}" ]] ||
    die "--region is required unless --skip-associations is used."
fi

if [[ -n "${AWS_PROFILE_NAME}" ]]; then
  export AWS_PROFILE="${AWS_PROFILE_NAME}"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vertex-pod-identity.XXXXXX")"
cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

CALLER_JSON="$(aws sts get-caller-identity --output json)"
AWS_ACCOUNT_ID="$(jq -r '.Account' <<<"${CALLER_JSON}")"
CALLER_ARN="$(jq -r '.Arn' <<<"${CALLER_JSON}")"
ARN_WITHOUT_PREFIX="${CALLER_ARN#arn:}"
AWS_PARTITION="${ARN_WITHOUT_PREFIX%%:*}"

[[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] ||
  die "Unable to determine the 12-digit AWS account ID."
[[ -n "${AWS_PARTITION}" && "${AWS_PARTITION}" != "${CALLER_ARN}" ]] ||
  die "Unable to determine the AWS partition from caller ARN ${CALLER_ARN}."

render_policy() {
  local source_file="$1"
  local destination_file="$2"
  local palette_role_arn="${3:-}"

  sed \
    -e "s|__AWS_PARTITION__|${AWS_PARTITION}|g" \
    -e "s|__PALETTE_ROLE_ARN__|${palette_role_arn}|g" \
    "${source_file}" >"${destination_file}"
  jq empty "${destination_file}"
}

ensure_role() {
  local role_name="$1"

  if aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    info "Updating Pod Identity trust policy on ${role_name}."
    aws iam update-assume-role-policy \
      --role-name "${role_name}" \
      --policy-document "file://${POLICY_DIR}/trust.json"
  else
    info "Creating IAM role ${role_name}."
    aws iam create-role \
      --role-name "${role_name}" \
      --description "Palette VerteX EKS Pod Identity role" \
      --assume-role-policy-document "file://${POLICY_DIR}/trust.json" \
      --tags Key=ManagedBy,Value=navy-deploy-pod-identity >/dev/null
  fi
}

role_arn() {
  aws iam get-role \
    --role-name "$1" \
    --query 'Role.Arn' \
    --output text
}

trim_policy_versions_if_needed() {
  local policy_arn="$1"
  local version_count
  local oldest_nondefault

  version_count="$(aws iam list-policy-versions \
    --policy-arn "${policy_arn}" \
    --query 'length(Versions)' \
    --output text)"
  if (( version_count < 5 )); then
    return
  fi

  oldest_nondefault="$(aws iam list-policy-versions \
    --policy-arn "${policy_arn}" \
    --query 'sort_by(Versions[?IsDefaultVersion==`false`],&CreateDate)[0].VersionId' \
    --output text)"
  [[ -n "${oldest_nondefault}" && "${oldest_nondefault}" != "None" ]] ||
    die "Could not select an old version of ${policy_arn} to remove."

  aws iam delete-policy-version \
    --policy-arn "${policy_arn}" \
    --version-id "${oldest_nondefault}"
}

ensure_managed_policy() {
  local policy_name="$1"
  local policy_file="$2"
  local description="$3"
  local policy_arn="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}"
  local default_version
  local current_file="${WORK_DIR}/${policy_name}.current.json"
  local current_normalized="${WORK_DIR}/${policy_name}.current.normalized.json"
  local desired_normalized="${WORK_DIR}/${policy_name}.desired.normalized.json"

  if ! aws iam get-policy --policy-arn "${policy_arn}" >/dev/null 2>&1; then
    info "Creating customer-managed policy ${policy_name}."
    aws iam create-policy \
      --policy-name "${policy_name}" \
      --description "${description}" \
      --policy-document "file://${policy_file}" \
      --tags Key=ManagedBy,Value=navy-deploy-pod-identity >/dev/null
    printf '%s\n' "${policy_arn}"
    return
  fi

  default_version="$(aws iam get-policy \
    --policy-arn "${policy_arn}" \
    --query 'Policy.DefaultVersionId' \
    --output text)"
  aws iam get-policy-version \
    --policy-arn "${policy_arn}" \
    --version-id "${default_version}" \
    --query 'PolicyVersion.Document' \
    --output json >"${current_file}"
  jq -S . "${current_file}" >"${current_normalized}"
  jq -S . "${policy_file}" >"${desired_normalized}"

  if cmp -s "${current_normalized}" "${desired_normalized}"; then
    info "Customer-managed policy ${policy_name} is current."
    printf '%s\n' "${policy_arn}"
    return
  fi

  info "Creating a new default version of ${policy_name}."
  trim_policy_versions_if_needed "${policy_arn}"
  aws iam create-policy-version \
    --policy-arn "${policy_arn}" \
    --policy-document "file://${policy_file}" \
    --set-as-default >/dev/null
  printf '%s\n' "${policy_arn}"
}

attach_managed_policy() {
  local role_name="$1"
  local policy_arn="$2"

  info "Attaching ${policy_arn##*/} to ${role_name}."
  aws iam attach-role-policy \
    --role-name "${role_name}" \
    --policy-arn "${policy_arn}"
}

detach_managed_policy() {
  local role_name="$1"
  local policy_arn="$2"
  local attached_policy_arn

  attached_policy_arn="$(aws iam list-attached-role-policies \
    --role-name "${role_name}" \
    --query "AttachedPolicies[?PolicyArn=='${policy_arn}'].PolicyArn | [0]" \
    --output text)"
  if [[ "${attached_policy_arn}" == "${policy_arn}" ]]; then
    info "Detaching obsolete policy ${policy_arn##*/} from ${role_name}."
    aws iam detach-role-policy \
      --role-name "${role_name}" \
      --policy-arn "${policy_arn}"
  fi
}

put_inline_policy() {
  local role_name="$1"
  local policy_name="$2"
  local policy_file="$3"

  info "Applying inline policy ${policy_name} to ${role_name}."
  aws iam put-role-policy \
    --role-name "${role_name}" \
    --policy-name "${policy_name}" \
    --policy-document "file://${policy_file}"
}

ensure_association() {
  local namespace="$1"
  local service_account="$2"
  local association_role_arn="$3"
  local association_file="${WORK_DIR}/${namespace}-${service_account}.json"
  local association_id
  local current_role_arn

  aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --output json >"${association_file}"
  association_id="$(jq -r \
    --arg namespace "${namespace}" \
    --arg service_account "${service_account}" \
    '[.associations[] |
      select(.namespace == $namespace and .serviceAccount == $service_account) |
      .associationId][0] // empty' "${association_file}")"

  if [[ -z "${association_id}" ]]; then
    info "Creating Pod Identity association ${namespace}/${service_account}."
    aws eks create-pod-identity-association \
      --cluster-name "${CLUSTER_NAME}" \
      --namespace "${namespace}" \
      --service-account "${service_account}" \
      --role-arn "${association_role_arn}" \
      --region "${REGION}" >/dev/null
    return
  fi

  current_role_arn="$(aws eks describe-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --association-id "${association_id}" \
    --region "${REGION}" \
    --query 'association.roleArn' \
    --output text)"
  if [[ "${current_role_arn}" == "${association_role_arn}" ]]; then
    info "Pod Identity association ${namespace}/${service_account} is current."
    return
  fi

  info "Updating Pod Identity association ${namespace}/${service_account}."
  aws eks update-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --association-id "${association_id}" \
    --role-arn "${association_role_arn}" \
    --region "${REGION}" >/dev/null
}

if [[ "${NETWORK_MODE}" == "existing" ]]; then
  LIFECYCLE_TEMPLATE="${POLICY_DIR}/palette-minimum-eks-static.json.tpl"
  LIFECYCLE_LABEL="minimum-static"
else
  LIFECYCLE_TEMPLATE="${POLICY_DIR}/palette-minimum-eks-dynamic.json.tpl"
  LIFECYCLE_LABEL="minimum-dynamic"
fi

LIFECYCLE_POLICY_FILE="${WORK_DIR}/palette-lifecycle.json"
IDENTITY_POLICY_FILE="${WORK_DIR}/identity.json"
render_policy "${LIFECYCLE_TEMPLATE}" "${LIFECYCLE_POLICY_FILE}"

info "AWS account: ${AWS_ACCOUNT_ID}"
info "AWS partition: ${AWS_PARTITION}"
info "Palette network permission mode: ${LIFECYCLE_LABEL}"
info "Role creation order: Palette -> Hubble -> Identity"
if [[ "${CREATE_ASSOCIATIONS}" == "true" ]]; then
  info "Management cluster: ${CLUSTER_NAME} (${REGION})"
else
  warn "Pod Identity associations will not be created."
fi

if [[ "${ASSUME_YES}" != "true" ]]; then
  [[ -t 0 ]] || die "No interactive terminal is available; rerun with --yes."
  read -r -p "Create or update these IAM/EKS resources? [y/N] " confirmation
  [[ "${confirmation}" =~ ^[Yy]$ ]] || die "Cancelled."
fi

# 1. Palette role. This must exist before the Identity role policy is rendered.
ensure_role "${PALETTE_ROLE_NAME}"
PALETTE_ROLE_ARN="$(role_arn "${PALETTE_ROLE_NAME}")"

LIFECYCLE_POLICY_ARN="$(ensure_managed_policy \
  "PaletteMinimumEKS-${LIFECYCLE_LABEL}-${NAME_SUFFIX}" \
  "${LIFECYCLE_POLICY_FILE}" \
  "Spectro Cloud minimum EKS permissions (${LIFECYCLE_LABEL})")"
attach_managed_policy "${PALETTE_ROLE_NAME}" "${LIFECYCLE_POLICY_ARN}"

if [[ "${LIFECYCLE_LABEL}" == "minimum-static" ]]; then
  OBSOLETE_LIFECYCLE_LABEL="minimum-dynamic"
else
  OBSOLETE_LIFECYCLE_LABEL="minimum-static"
fi
detach_managed_policy \
  "${PALETTE_ROLE_NAME}" \
  "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/PaletteMinimumEKS-${OBSOLETE_LIFECYCLE_LABEL}-${NAME_SUFFIX}"

if [[ "${MANAGE_CLOUDFORMATION}" == "true" ]]; then
  CLOUDFORMATION_POLICY_ARN="$(ensure_managed_policy \
    "PaletteCAPACloudFormation-${NAME_SUFFIX}" \
    "${POLICY_DIR}/palette-cloudformation-automatic.json" \
    "Spectro Cloud automatic CAPA CloudFormation management")"
  attach_managed_policy "${PALETTE_ROLE_NAME}" "${CLOUDFORMATION_POLICY_ARN}"
else
  detach_managed_policy \
    "${PALETTE_ROLE_NAME}" \
    "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/PaletteCAPACloudFormation-${NAME_SUFFIX}"
fi

put_inline_policy \
  "${PALETTE_ROLE_NAME}" \
  "SpectroCloudPodIdentity" \
  "${POLICY_DIR}/palette-pod-identity.json"

# 2. Hubble validation role.
ensure_role "${HUBBLE_ROLE_NAME}"
HUBBLE_ROLE_ARN="$(role_arn "${HUBBLE_ROLE_NAME}")"
put_inline_policy \
  "${HUBBLE_ROLE_NAME}" \
  "SpectroCloudHubbleValidation" \
  "${POLICY_DIR}/hubble.json"

# 3. Identity role. Its policy is scoped to the Palette role created in step 1.
ensure_role "${IDENTITY_ROLE_NAME}"
IDENTITY_ROLE_ARN="$(role_arn "${IDENTITY_ROLE_NAME}")"
render_policy \
  "${POLICY_DIR}/identity.json.tpl" \
  "${IDENTITY_POLICY_FILE}" \
  "${PALETTE_ROLE_ARN}"
put_inline_policy \
  "${IDENTITY_ROLE_NAME}" \
  "SpectroCloudIdentity" \
  "${IDENTITY_POLICY_FILE}"

if [[ "${CREATE_ASSOCIATIONS}" == "true" ]]; then
  ensure_association \
    "hubble-system" \
    "spectro-hubble" \
    "${HUBBLE_ROLE_ARN}"
  ensure_association \
    "palette-identity" \
    "palette-identity" \
    "${IDENTITY_ROLE_ARN}"
fi

printf '\nCompleted.\n'
printf 'Palette role:  %s\n' "${PALETTE_ROLE_ARN}"
printf 'Hubble role:   %s\n' "${HUBBLE_ROLE_ARN}"
printf 'Identity role: %s\n' "${IDENTITY_ROLE_ARN}"
printf '\nUse the Palette role ARN when registering the AWS cloud account in VerteX.\n'
printf 'Do not manually associate the Palette role; VerteX creates that association when needed.\n'
