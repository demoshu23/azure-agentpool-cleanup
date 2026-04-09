#!/usr/bin/env bash
set -euo pipefail

ORG_URL="${AZDO_ORG_URL:?AZDO_ORG_URL is required}"
PAT_TOKEN="${AZDO_PAT:?AZDO_PAT is required}"
API_VERSION="7.1-preview.1"

MAX_INACTIVE_DAYS="${MAX_INACTIVE_DAYS:-30}"
IGNORE_POOL_NAMES="${IGNORE_POOL_NAMES:-}"
IGNORE_POOL_PREFIX="${IGNORE_POOL_PREFIX:-}"

ORG_URL="${ORG_URL%/}"
ENCODED_PAT=$(printf ":%s" "$PAT_TOKEN" | base64 | tr -d '\r\n')

now_epoch=$(date +%s)
IFS=',' read -r -a IGNORE_POOL_NAMES_ARR <<< "$IGNORE_POOL_NAMES"

log() {
  echo "[$(date -Iseconds)] $*"
}

call_api() {
  local method="$1"
  local url="$2"

  response=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    -X "$method" \
    -H "Authorization: Basic $ENCODED_PAT" \
    -H "Content-Type: application/json" \
    --connect-timeout 15 \
    --retry 3 \
    --retry-delay 2 \
    "$url")

  body=$(echo "$response" | sed -e 's/HTTP_STATUS:.*//g')
  status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')

  log "HTTP $method $url -> $status"

  if [[ "$status" -ne 200 ]]; then
    log "ERROR: API failed"
    echo "$body"
    exit 1
  fi

  # Validate JSON strictly
  echo "$body" | jq . >/dev/null 2>&1 || {
    log "ERROR: Invalid JSON from API"
    echo "$body"
    exit 1
  }

  echo "$body"
}

should_ignore_pool() {
  local pool_name="$1"

  [[ -n "$IGNORE_POOL_PREFIX" && "$pool_name" == "$IGNORE_POOL_PREFIX"* ]] && return 0

  for n in "${IGNORE_POOL_NAMES_ARR[@]}"; do
    [[ -n "$n" && "$pool_name" == "$n" ]] && return 0
  done

  return 1
}

log "Fetching agent pools..."

pools_json=$(call_api GET "$ORG_URL/_apis/distributedtask/pools?api-version=$API_VERSION")

# SAFE iteration (no pipe!)
mapfile -t pools < <(echo "$pools_json" | jq -c '.value[]')

for pool in "${pools[@]}"; do
  pool_id=$(jq -r '.id' <<< "$pool")
  pool_name=$(jq -r '.name' <<< "$pool")

  if should_ignore_pool "$pool_name"; then
    log "Skipping pool '$pool_name'"
    continue
  fi

  log "Processing pool '$pool_name' (id=$pool_id)"

  agents_json=$(call_api GET "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents?includeCapabilities=true&includeAssignedRequest=true&api-version=$API_VERSION")

  mapfile -t agents < <(echo "$agents_json" | jq -c '.value[]')

  for agent in "${agents[@]}"; do
    agent_id=$(jq -r '.id' <<< "$agent")
    agent_name=$(jq -r '.name' <<< "$agent")
    status=$(jq -r '.status' <<< "$agent")
    last_online_time=$(jq -r '.lastOnlineOn // empty' <<< "$agent")

    if [[ -n "$last_online_time" ]]; then
      last_online_epoch=$(date -d "$last_online_time" +%s 2>/dev/null || echo "$now_epoch")
      diff_days=$(( (now_epoch - last_online_epoch) / 86400 ))
    else
      diff_days="$MAX_INACTIVE_DAYS"
    fi

    if [[ "$status" == "offline" && "$diff_days" -ge "$MAX_INACTIVE_DAYS" ]]; then
      log "Deleting agent '$agent_name' (${diff_days}d inactive)"
      call_api DELETE "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents/$agent_id?api-version=$API_VERSION" >/dev/null
    else
      log "Keeping agent '$agent_name' (${diff_days}d inactive)"
    fi
  done

  remaining=$(call_api GET "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents?api-version=$API_VERSION" | jq '.value | length')

  if [[ "$remaining" -eq 0 ]]; then
    log "Deleting empty pool '$pool_name'"
    call_api DELETE "$ORG_URL/_apis/distributedtask/pools/$pool_id?api-version=$API_VERSION" >/dev/null
  else
    log "Pool '$pool_name' has $remaining agents"
  fi
done

log "Cleanup completed."