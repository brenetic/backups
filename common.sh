#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-"$SCRIPT_DIR/.env"}"
TARGETS_FILE="${TARGETS_FILE:-"$SCRIPT_DIR/targets.json"}"
HOSTNAME_SHORT="$(hostname -s || hostname || echo unknown)"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

_TELEGRAM_URL=""
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  _TELEGRAM_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
fi

tg() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >&2
  [[ -z "$_TELEGRAM_URL" ]] && return 0
  curl -fsS --max-time 10 --retry 2 \
    --data "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$msg" \
    --data "disable_web_page_preview=true" \
    "$_TELEGRAM_URL" >/dev/null || true
}

on_error() {
  local ec=$? line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
  tg "[ERROR] Backup aborted (exit $ec) at line $line: $cmd"
  exit $ec
}

validate_command() {
  local cmd="$1"
  local error_level="${2:-ERROR}"

  if ! command -v "$cmd" >/dev/null; then
    if [[ "$error_level" == "ERROR" ]]; then
      echo "[$error_level] $cmd not found"
      exit 1
    else
      echo "[$error_level] $cmd missing; functionality may be disabled"
    fi
  fi
}

validate_targets_file() {
  [[ -f "$TARGETS_FILE" ]] || {
    tg "[ERROR] targets.json not found at $TARGETS_FILE"
    exit 1
  }
  jq empty "$TARGETS_FILE" >/dev/null || {
    tg "[ERROR] targets.json is invalid JSON"
    exit 1
  }
}

calculate_elapsed_time() {
  local start_epoch="$1"
  local end_epoch="$2"
  local elapsed_secs=$((end_epoch - start_epoch))
  local elapsed_min=$((elapsed_secs / 60))
  local elapsed_sec=$((elapsed_secs % 60))

  echo "${elapsed_min}m ${elapsed_sec}s"
}

print_final_summary() {
  local end_ts="$1"
  local processed="$2"
  local total="$3"
  local failed="$4"
  local elapsed_time="$5"
  local backup_type="${6:-Backup}"

  if (( failed == 0 )); then
    tg "[OK] $backup_type finished @ $end_ts
Processed: $processed / $total
Failed: $failed
Duration: $elapsed_time"
  else
    tg "[ERROR] $backup_type finished with errors @ $end_ts
Processed: $processed / $total
Failed: $failed
Duration: $elapsed_time"
  fi
}

