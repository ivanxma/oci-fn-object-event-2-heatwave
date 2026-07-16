#!/usr/bin/env bash
# Creates/updates the OCI Functions application, deploys the image, assigns
# DB_* function properties, and creates an Object Storage event rule.
set -euo pipefail
umask 077

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPORT="$ROOT_DIR/function-report.html"
DEPLOY_DIR=$(mktemp -d)
ENV_FILE="${ENV_FILE:-$ROOT_DIR/env.sh}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy env.sh.example to env.sh and set local deployment values." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
 : "${COMPARTMENT_ID:?Set COMPARTMENT_ID in env.sh}"
 : "${VCN_NAME:?Set VCN_NAME in env.sh}"
SUBNET_ID="${SUBNET_ID:-}"
: "${APP_NAME:?Set APP_NAME in env.sh}"
: "${FUNCTION_NAME:?Set FUNCTION_NAME in env.sh}"
: "${REGION:?Set REGION in env.sh}"
: "${REGION_KEY:?Set REGION_KEY in env.sh}"
: "${REPOSITORY_PREFIX:?Set REPOSITORY_PREFIX in env.sh}"
: "${DB_HOST:?Set DB_HOST in env.sh}"
: "${DB_PORT:?Set DB_PORT in env.sh}"
: "${DB_NAME:?Set DB_NAME in env.sh}"
: "${DB_USER:?Set DB_USER in env.sh}"
: "${DB_PASSWORD:?Set DB_PASSWORD in env.sh}"
: "${OCIR_USERNAME:?Set OCIR_USERNAME in env.sh}"
: "${OCIR_AUTH_TOKEN:?Set OCIR_AUTH_TOKEN in env.sh}"
cleanup() {
  rm -f "${CONFIG_FILE:-}"
  rm -rf "$DEPLOY_DIR"
}
trap cleanup EXIT
# Object Storage and the Events rule are deliberately confined to the same
# HWDemo compartment as the Function application.
OBJECT_STORAGE_COMPARTMENT_ID="${OBJECT_STORAGE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
if [[ "$OBJECT_STORAGE_COMPARTMENT_ID" != "$COMPARTMENT_ID" ]]; then
  echo "OBJECT_STORAGE_COMPARTMENT_ID must be the same HWDemo compartment as the Function application." >&2
  exit 1
fi

for command in oci fn podman jq; do command -v "$command" >/dev/null || { echo "Missing $command; run ./bootstrap.sh first." >&2; exit 1; }; done
OCI=(oci --auth instance_principal)
NAMESPACE=$("${OCI[@]}" os ns get --query data --raw-output)
REPOSITORY_NAME="$REPOSITORY_PREFIX/$FUNCTION_NAME"

VCN_ID="not queried (SUBNET_ID supplied)"
if [[ -z "$SUBNET_ID" ]]; then
  if ! VCN_ID=$("${OCI[@]}" network vcn list --compartment-id "$COMPARTMENT_ID" --all \
    --query "data[?\"display-name\"=='$VCN_NAME'].id | [0]" --raw-output); then
    cat >&2 <<'EOF'
Cannot list VCNs with the instance principal. Either grant it:
  Allow dynamic-group <deployer-dynamic-group> to read virtual-network-family in compartment HWDemo
or obtain the private subnet OCID from an OCI administrator and re-run with:
  export SUBNET_ID='private-subnet-ocid-from-console'
EOF
    exit 1
  fi
  [[ -n "$VCN_ID" && "$VCN_ID" != "null" ]] || { echo "VCN not found: $VCN_NAME" >&2; exit 1; }
  SUBNET_ID=$("${OCI[@]}" network subnet list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --all \
    --query 'data[?"prohibit-public-ip-on-vnic"==`true`].id | [0]' --raw-output)
  [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "null" ]] || { echo "No private subnet found in $VCN_NAME" >&2; exit 1; }
fi

APP_ID=$("${OCI[@]}" fn application list --compartment-id "$COMPARTMENT_ID" --all \
  --query "data[?\"display-name\"=='$APP_NAME'].id | [0]" --raw-output)
if [[ -z "$APP_ID" || "$APP_ID" == "null" ]]; then
  APP_ID=$("${OCI[@]}" fn application create --compartment-id "$COMPARTMENT_ID" --display-name "$APP_NAME" \
    --subnet-ids "[\"$SUBNET_ID\"]" --query 'data.id' --raw-output)
fi

# Repositories created implicitly on first image push are placed in the tenancy
# root compartment. Create this private repository explicitly in HWDemo instead.
REPOSITORY_ID=$("${OCI[@]}" artifacts container repository list --compartment-id "$COMPARTMENT_ID" --all \
  --query "data.items[?\"display-name\"=='$REPOSITORY_NAME'].id | [0]" --raw-output) || {
  echo "Cannot inspect OCIR repositories. Grant the instance dynamic group: manage repos in compartment HWDemo." >&2
  exit 1
}
if [[ -z "$REPOSITORY_ID" || "$REPOSITORY_ID" == "null" ]]; then
  REPOSITORY_ID=$("${OCI[@]}" artifacts container repository create --compartment-id "$COMPARTMENT_ID" \
    --display-name "$REPOSITORY_NAME" --is-public false --query 'data.id' --raw-output)
fi

export PATH="$HOME/.fn/bin:$HOME/bin:$PATH"
fn create context "$REGION" --provider oracle-ip 2>/dev/null || true
# Fn 0.6.62 returns a non-zero status when asked to use the context that is
# already active.  It is safe to continue: subsequent update commands verify
# the active context is usable.
fn use context "$REGION" 2>/dev/null || true
fn update context oracle.compartment-id "$COMPARTMENT_ID"
fn update context api-url "https://functions.$REGION.oci.oraclecloud.com"
fn update context registry "$REGION_KEY.ocir.io/$NAMESPACE/$REPOSITORY_PREFIX"
printf '%s' "$OCIR_AUTH_TOKEN" | podman login "$REGION_KEY.ocir.io" --username "$OCIR_USERNAME" --password-stdin

# Fn reads the function name from func.yaml and does not expand shell variables
# there. Build from a temporary definition whose name comes from env.sh, leaving
# the checked-in func.yaml reusable for any FUNCTION_NAME.
cp "$ROOT_DIR/Dockerfile" "$ROOT_DIR/func.py" "$ROOT_DIR/requirements.txt" "$DEPLOY_DIR/"
awk -v function_name="$FUNCTION_NAME" '
  /^name:[[:space:]]*/ { print "name: " function_name; next }
  { print }
' "$ROOT_DIR/func.yaml" > "$DEPLOY_DIR/func.yaml"

cd "$DEPLOY_DIR"
fn -v deploy --app "$APP_NAME"
FUNCTION_ID=$("${OCI[@]}" fn function list --application-id "$APP_ID" --all \
  --query "data[?\"display-name\"=='$FUNCTION_NAME'].id | [0]" --raw-output)
CONFIG_FILE=$(mktemp)
jq -n --arg host "$DB_HOST" --arg port "$DB_PORT" --arg name "$DB_NAME" --arg user "$DB_USER" --arg password "$DB_PASSWORD" \
  '{DB_HOST:$host,DB_PORT:$port,DB_NAME:$name,DB_USER:$user,DB_PASSWORD:$password}' > "$CONFIG_FILE"
"${OCI[@]}" fn function update --function-id "$FUNCTION_ID" --config "file://$CONFIG_FILE" --force >/dev/null

RULE_NAME="${RULE_NAME:-object-storage-heatwave-events}"
CONDITION=$(jq -nc --arg compartment "$OBJECT_STORAGE_COMPARTMENT_ID" '{eventType:["com.oraclecloud.objectstorage.createobject","com.oraclecloud.objectstorage.deleteobject","com.oraclecloud.objectstorage.updateobject"],data:{compartmentId:$compartment}}')
ACTIONS=$(jq -nc --arg functionId "$FUNCTION_ID" '{actions:[{actionType:"FAAS",isEnabled:true,description:"Send Object Storage events to HeatWave function",functionId:$functionId}]}')
RULE_ID=$("${OCI[@]}" events rule list --compartment-id "$COMPARTMENT_ID" --all --query "data[?\"display-name\"=='$RULE_NAME'].id | [0]" --raw-output)
if [[ -z "$RULE_ID" || "$RULE_ID" == "null" ]]; then
  "${OCI[@]}" events rule create --compartment-id "$COMPARTMENT_ID" --display-name "$RULE_NAME" --condition "$CONDITION" --actions "$ACTIONS" --is-enabled true >/dev/null
else
  "${OCI[@]}" events rule update --rule-id "$RULE_ID" --condition "$CONDITION" --actions "$ACTIONS" --force >/dev/null
fi
"$ROOT_DIR/generate_report.sh" "$REPORT" "$COMPARTMENT_ID" "$VCN_ID" "$SUBNET_ID" "$APP_ID" "$FUNCTION_ID"
echo "Deployment complete. Report: $REPORT"
