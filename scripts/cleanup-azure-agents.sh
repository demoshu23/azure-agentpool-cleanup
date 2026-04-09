#!/usr/bin/env bash
set -euo pipefail

ORG_URL="${AZDO_ORG_URL:?AZDO_ORG_URL is required}"
PAT_TOKEN="${AZDO_PAT:?AZDO_PAT is required}"
API_VERSION="7.1-preview.1"

MAX_INACTIVE_DAYS="${MAX_INACTIVE_DAYS:-30}"
IGNORE_POOL_NAMES="${IGNORE_POOL_NAMES:-}"
IGNORE_POOL_PREFIX="${IGNORE_POOL_PREFIX:-}"

ENCODED_PAT=$(printf ":%s" "$PAT_TOKEN" | base64)
now_epoch=$(date +%s)

IFS=',' read -r -a IGNORE_POOL_NAMES_ARR <<< "$IGNORE_POOL_NAMES"

log() {
  echo "[$(date -Iseconds)] $*"
}

call_api() {
  local method="$1"
  local url="$2"
  curl -sS -X "$method" \
    -H "Authorization: Basic $ENCODED_PAT" \
    -H "Content-Type: application/json" \
    "$url"
}

should_ignore_pool() {
  local pool_name="$1"

  if [[ -n "$IGNORE_POOL_PREFIX" && "$pool_name" == "$IGNORE_POOL_PREFIX"* ]]; then
    return 0
  fi

  for n in "${IGNORE_POOL_NAMES_ARR[@]}"; do
    [[ -z "$n" ]] && continue
    if [[ "$pool_name" == "$n" ]]; then
      return 0
    fi
  done

  return 1
}

log "Fetching agent pools..."
pools_json=$(call_api GET "$ORG_URL/_apis/distributedtask/pools?api-version=$API_VERSION")

echo "$pools_json" | jq -c '.value[]' | while read -r pool; do
  pool_id=$(echo "$pool" | jq -r '.id')
  pool_name=$(echo "$pool" | jq -r '.name')

  if should_ignore_pool "$pool_name"; then
    log "Skipping pool '$pool_name' due to policy"
    continue
  fi

  log "Processing pool '$pool_name' (id=$pool_id)"

  agents_json=$(call_api GET "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents?includeCapabilities=true&includeAssignedRequest=true&api-version=$API_VERSION")

  echo "$agents_json" | jq -c '.value[]' | while read -r agent; do
    agent_id=$(echo "$agent" | jq -r '.id')
    agent_name=$(echo "$agent" | jq -r '.name')
    status=$(echo "$agent" | jq -r '.status')
    last_online_time=$(echo "$agent" | jq -r '.lastOnlineOn // empty')

    if [[ -n "$last_online_time" ]]; then
      last_online_epoch=$(date -d "$last_online_time" +%s || echo "$now_epoch")
      diff_days=$(( (now_epoch - last_online_epoch) / 86400 ))
    else
      diff_days="$MAX_INACTIVE_DAYS"
    fi

    if [[ "$status" == "offline" && "$diff_days" -ge "$MAX_INACTIVE_DAYS" ]]; then
      log "Deleting stale agent '$agent_name' (inactive ${diff_days}d)"
      call_api DELETE "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents/$agent_id?api-version=$API_VERSION" >/dev/null
    else
      log "Keeping agent '$agent_name' (inactive ${diff_days}d)"
    fi
  done

  remaining=$(call_api GET "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents?api-version=$API_VERSION" | jq '.value | length')

  if [[ "$remaining" -eq 0 ]]; then
    log "Deleting empty pool '$pool_name'"
    call_api DELETE "$ORG_URL/_apis/distributedtask/pools/$pool_id?api-version=$API_VERSION" >/dev/null
  else
    log "Pool '$pool_name' still has $remaining agents"
  fi
done

log "Cleanup completed."
