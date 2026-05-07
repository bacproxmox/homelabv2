#!/usr/bin/env bash
set -euo pipefail

log() {
  echo ""
  echo ">>> $1"
}

ok() {
  echo "✅ $1"
}

warn() {
  echo "⚠️  $1"
}

fail() {
  echo "❌ $1"
  exit 1
}

require_var() {
  local var_name="$1"

  if [[ -z "${!var_name:-}" ]]; then
    fail "Missing variable: $var_name"
  fi

  if [[ "${!var_name}" == "CHANGE_ME" ]]; then
    fail "Variable still has CHANGE_ME value: $var_name"
  fi
}

wait_for_url() {
  local url="$1"
  local name="$2"

  log "Waiting for $name: $url"

  for i in {1..30}; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      ok "$name is reachable"
      return 0
    fi

    sleep 2
  done

  fail "$name is not reachable: $url"
}

api_get() {
  local url="$1"
  local api_key="$2"

  curl -fsS \
    -H "X-Api-Key: $api_key" \
    "$url"
}

api_post() {
  local url="$1"
  local api_key="$2"
  local payload="$3"

  curl -fsS \
    -H "X-Api-Key: $api_key" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    "$url"
}
