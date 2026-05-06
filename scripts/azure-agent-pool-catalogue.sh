#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------
# CONFIG (from Azure DevOps Library Group)
# ---------------------------------------------------------
AZP_ORG_URL="${AZP_ORG_URL:?Missing AZP_ORG_URL}"          # e.g. https://dev.azure.com/shumart2025
AZP_TOKEN="${AZP_TOKEN:?Missing AZP_TOKEN}"                # PAT with Agent Pools (Read) + Service Connections (Read)
AZP_PROJECT="${AZP_PROJECT:-}"                             # optional, not required for pools

OUT_DIR="${OUT_DIR:-agent-pool-catalogue}"
mkdir -p "$OUT_DIR"

CATALOG_JSON="${OUT_DIR}/agent-pools.json"
CATALOG_TABLE="${OUT_DIR}/agent-pools.txt"

auth_header() {
  printf ":${AZP_TOKEN}"
}

log() {
  echo "[INFO] $1"
}

# ---------------------------------------------------------
# 1. Fetch pools
# ---------------------------------------------------------
log "Fetching agent pools from: ${AZP_ORG_URL}"

curl -s -u "$(auth_header)" \
  "${AZP_ORG_URL}/_apis/distributedtask/pools?api-version=7.1-preview.1" \
  > "${CATALOG_JSON}"

log "Agent pools JSON saved to: ${CATALOG_JSON}"

# ---------------------------------------------------------
# 2. Build human-readable table
# ---------------------------------------------------------
log "Building agent pool catalogue table..."

{
  echo "POOL_ID | POOL_NAME | IS_HOSTED | AGENT_ID | AGENT_NAME | STATUS | OS_DESCRIPTION | VERSION"
  echo "--------|-----------|-----------|----------|------------|--------|----------------|--------"
} > "${CATALOG_TABLE}"

POOL_IDS=$(jq -r '.value[].id' "${CATALOG_JSON}")

for POOL_ID in $POOL_IDS; do
  POOL_NAME=$(jq -r ".value[] | select(.id==${POOL_ID}) | .name" "${CATALOG_JSON}")
  IS_HOSTED=$(jq -r ".value[] | select(.id==${POOL_ID}) | .isHosted" "${CATALOG_JSON}")

  log "Processing pool: ${POOL_NAME} (ID: ${POOL_ID})"

  AGENTS_JSON="${OUT_DIR}/agents-pool-${POOL_ID}.json"

  curl -s -u "$(auth_header)" \
    "${AZP_ORG_URL}/_apis/distributedtask/pools/${POOL_ID}/agents?includeCapabilities=true&api-version=7.1-preview.1" \
    > "${AGENTS_JSON}"

  AGENT_IDS=$(jq -r '.value[].id' "${AGENTS_JSON}")

  if [[ -z "${AGENT_IDS}" ]]; then
    echo "${POOL_ID} | ${POOL_NAME} | ${IS_HOSTED} | - | - | - | - | -" >> "${CATALOG_TABLE}"
    continue
  fi

  for AGENT_ID in $AGENT_IDS; do
    AGENT_NAME=$(jq -r ".value[] | select(.id==${AGENT_ID}) | .name" "${AGENTS_JSON}")
    STATUS=$(jq -r ".value[] | select(.id==${AGENT_ID}) | .status" "${AGENTS_JSON}")
    OS_DESC=$(jq -r ".value[] | select(.id==${AGENT_ID}) | .systemCapabilities.\"Agent.OSDescription\"" "${AGENTS_JSON}")
    VERSION=$(jq -r ".value[] | select(.id==${AGENT_ID}) | .version" "${AGENTS_JSON}")

    echo "${POOL_ID} | ${POOL_NAME} | ${IS_HOSTED} | ${AGENT_ID} | ${AGENT_NAME} | ${STATUS} | ${OS_DESC} | ${VERSION}" \
      >> "${CATALOG_TABLE}"
  done
done

log "Agent pool catalogue table saved to: ${CATALOG_TABLE}"
log "Done."
