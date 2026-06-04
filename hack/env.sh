#!/usr/bin/env bash
# env.sh — ACP cluster environment variables
# Usage: source ./hack/env.sh
#
# Fill in the values below for your deployment, then source this file
# before running any hack/ script. Values are never committed to git.
#
# Example:
#   export CLUSTER_NAME="acp"
#   export BASE_DOMAIN="example.com"
#   export EXTERNAL_IP="1.2.3.4"
#   export HOSTED_ZONE_ID="ZXXXXXXXXXXXXX"
#   source ./hack/env.sh

# ── Required: fill these in ────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-acp}"
export BASE_DOMAIN="${BASE_DOMAIN:-sandbox3377.opentlc.com}"
export EXTERNAL_IP="${EXTERNAL_IP:-150.240.0.146}"
export HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z0784382GK56DNTZT2QJ}"

# ── Optional: cluster network VIPs (defaults match examples/ibm-cloud-converged/) ────
export API_VIP="${API_VIP:-192.168.50.253}"
export INGRESS_VIP="${INGRESS_VIP:-192.168.50.252}"

# ── Validate that required values are set ─────────────────────────────────────
_missing=()
for _var in BASE_DOMAIN EXTERNAL_IP HOSTED_ZONE_ID; do
    _val="${!_var}"
    if [[ "${_val}" == "<"*">" || -z "${_val}" ]]; then
        _missing+=("${_var}")
    fi
done

if [[ ${#_missing[@]} -gt 0 ]]; then
    echo "[WARN] The following environment variables are not set in hack/env.sh:"
    for _v in "${_missing[@]}"; do
        echo "  ${_v}=${!_v}"
    done
    echo "  Edit hack/env.sh or export the variables before sourcing."
else
    echo "[INFO] ACP environment loaded: ${CLUSTER_NAME}.${BASE_DOMAIN} (${EXTERNAL_IP})"
fi
