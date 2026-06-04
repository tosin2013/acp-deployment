#!/usr/bin/env bash
# configure-route53-dns.sh — Manage Route53 DNS records for ACP cluster external access
# Usage: ./hack/configure-route53-dns.sh <add|delete>
#
# Required environment variables (set in hack/env.sh):
#   CLUSTER_NAME    - OpenShift cluster name (e.g., "acp")
#   BASE_DOMAIN     - Base DNS domain (e.g., "example.com")
#   EXTERNAL_IP     - IBM Cloud public IP (Route53 A records point HERE, not private IP)
#   HOSTED_ZONE_ID  - Route53 hosted zone ID for BASE_DOMAIN
#
# AWS credentials are read from ~/.aws/credentials (default profile).
#
# DNS records managed:
#   api.<CLUSTER_NAME>.<BASE_DOMAIN>      A → EXTERNAL_IP
#   api-int.<CLUSTER_NAME>.<BASE_DOMAIN>  A → EXTERNAL_IP
#   *.apps.<CLUSTER_NAME>.<BASE_DOMAIN>   A → EXTERNAL_IP
#
# TTL is set to 60 seconds for fast propagation during development.
#
# IMPORTANT: EXTERNAL_IP must be the PUBLIC IP, not the private IBM Cloud IP (10.x.x.x).
# Route53 resolvers are queried from outside the IBM Cloud network.

set -euo pipefail

ACTION="${1:-}"
[[ "${ACTION}" == "add" || "${ACTION}" == "delete" ]] || {
    echo "Usage: $0 <add|delete>"
    echo ""
    echo "  add    — Create Route53 A records pointing EXTERNAL_IP"
    echo "  delete — Delete the Route53 A records"
    exit 1
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

: "${CLUSTER_NAME:?ERROR: CLUSTER_NAME is not set. Source hack/env.sh first.}"
: "${BASE_DOMAIN:?ERROR: BASE_DOMAIN is not set. Source hack/env.sh first.}"
: "${EXTERNAL_IP:?ERROR: EXTERNAL_IP is not set. Source hack/env.sh first.}"
: "${HOSTED_ZONE_ID:?ERROR: HOSTED_ZONE_ID is not set. Source hack/env.sh first.}"

TTL=60
R53_ACTION=$([ "${ACTION}" = "add" ] && echo "UPSERT" || echo "DELETE")

info "Route53 DNS ${ACTION}: ${CLUSTER_NAME}.${BASE_DOMAIN}"
info "  Hosted zone  : ${HOSTED_ZONE_ID}"
info "  External IP  : ${EXTERNAL_IP}"
info "  Action       : ${R53_ACTION}"

# ── Build the change batch ─────────────────────────────────────────────────────
CHANGE_BATCH=$(cat <<EOF
{
  "Comment": "ACP cluster ${CLUSTER_NAME}.${BASE_DOMAIN} DNS records — ${ACTION} by configure-route53-dns.sh",
  "Changes": [
    {
      "Action": "${R53_ACTION}",
      "ResourceRecordSet": {
        "Name": "api.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${EXTERNAL_IP}"}]
      }
    },
    {
      "Action": "${R53_ACTION}",
      "ResourceRecordSet": {
        "Name": "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${EXTERNAL_IP}"}]
      }
    },
    {
      "Action": "${R53_ACTION}",
      "ResourceRecordSet": {
        "Name": "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}.",
        "Type": "A",
        "TTL": ${TTL},
        "ResourceRecords": [{"Value": "${EXTERNAL_IP}"}]
      }
    }
  ]
}
EOF
)

# ── Submit the change batch ────────────────────────────────────────────────────
info "Submitting Route53 change batch..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "${CHANGE_BATCH}" \
    --query 'ChangeInfo.Id' \
    --output text)

info "  Change submitted: ${CHANGE_ID}"

# ── Wait for propagation ───────────────────────────────────────────────────────
if [[ "${ACTION}" == "add" ]]; then
    info "Waiting for Route53 change to propagate (INSYNC)..."
    aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"
    info "  Route53 change is INSYNC"

    echo ""
    info "Verifying DNS propagation via 8.8.8.8 (up to 60s)..."
    for attempt in $(seq 1 6); do
        RESULT=$(dig @8.8.8.8 "api.${CLUSTER_NAME}.${BASE_DOMAIN}" +short 2>/dev/null | head -1 || true)
        if [[ "${RESULT}" == "${EXTERNAL_IP}" ]]; then
            info "  api.${CLUSTER_NAME}.${BASE_DOMAIN} → ${RESULT} ✓"
            break
        fi
        warn "  Attempt ${attempt}/6: got '${RESULT}', retrying in 10s..."
        sleep 10
    done

    echo ""
    info "Route53 records created:"
    info "  api.${CLUSTER_NAME}.${BASE_DOMAIN}     → ${EXTERNAL_IP}"
    info "  api-int.${CLUSTER_NAME}.${BASE_DOMAIN} → ${EXTERNAL_IP}"
    info "  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}  → ${EXTERNAL_IP}"
    info ""
    info "Next: Run ./hack/configure-haproxy-forwarder.sh (if not done already)"
    info "Then: Run ./hack/verify-dns-resolution.sh"
else
    info "Route53 records deleted:"
    info "  api.${CLUSTER_NAME}.${BASE_DOMAIN}"
    info "  api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
    info "  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
fi
