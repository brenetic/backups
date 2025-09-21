#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-"$SCRIPT_DIR/.env"}"
TARGETS_FILE="${TARGETS_FILE:-"$SCRIPT_DIR/targets.json"}"
HOSTNAME_SHORT="$(hostname -s || hostname || echo unknown)"

if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

: "${B2_BUCKET_NAME:?B2_BUCKET_NAME is required}"
: "${B2_ACCOUNT_ID:?B2_ACCOUNT_ID is required}"
: "${B2_ACCOUNT_KEY:?B2_ACCOUNT_KEY is required}"

RESTIC_AUTH_ARGS=()
if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
  RESTIC_AUTH_ARGS+=(--password-file "$RESTIC_PASSWORD_FILE")
elif [[ -n "${RESTIC_PASSWORD:-}" ]]; then
  RESTIC_AUTH_ARGS+=(--password-command 'echo "$RESTIC_PASSWORD"')
else
  echo "[ERROR] RESTIC_PASSWORD[_FILE] is required" >&2; exit 1
fi

command -v restic >/dev/null || { echo "[ERROR] restic not found"; exit 1; }
command -v jq     >/dev/null || { echo "[ERROR] jq not found"; exit 1; }
command -v curl   >/dev/null || { echo "[WARN] curl missing; Telegram disabled"; }

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
  tg "❌ Backup aborted (exit $ec) at line $line: $cmd"; exit $ec
}
trap on_error ERR INT TERM

build_repo_url() {
  local name="$1"
  echo "b2:${B2_BUCKET_NAME}:$name"
}
ensure_repo() {
  local repo_url="$1"
  if restic -r "$repo_url" "${RESTIC_AUTH_ARGS[@]}" cat config >/dev/null 2>&1; then
    return 0
  fi
  tg "ℹ️ Initialising repo → $repo_url"
  restic -r "$repo_url" "${RESTIC_AUTH_ARGS[@]}" init >/tmp/restic_init.log 2>&1 || {
    tg "❌ Repo init failed for $repo_url\n$(tail -n 60 /tmp/restic_init.log || true)"; return 1; }
}

run_retention() {
  local repo_url="$1" retention_json="${2:-null}"
  [[ "$retention_json" == "null" || -z "$retention_json" ]] && retention_json='{"keepWithin":"1m"}'
  local args=()
  while IFS="=" read -r k v; do
    case "$k" in
      keepLast) args+=(--keep-last "$v");;
      keepHourly) args+=(--keep-hourly "$v");;
      keepDaily) args+=(--keep-daily "$v");;
      keepWeekly) args+=(--keep-weekly "$v");;
      keepMonthly) args+=(--keep-monthly "$v");;
      keepYearly) args+=(--keep-yearly "$v");;
      keepWithin) args+=(--keep-within "$v");;
      groupBy) args+=(--group-by "$v");;
    esac
  done < <(echo "$retention_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  local out rc=0
  if ! out="$(restic -r "$repo_url" "${RESTIC_AUTH_ARGS[@]}" forget --prune "${args[@]}" 2>&1)"; then
    rc=$?; tg "⚠️ Retention failed for $repo_url (exit $rc)\n$(echo "$out" | tail -n 60)"; return $rc
  fi
  tg "🧹 Retention ok for $repo_url\n$(echo "$out" | tail -n 30)"
}

backup_target() {
  local target_json="$1"
  local name enabled retention_json
  name="$(echo "$target_json"    | jq -r '.repo')"
  enabled="$(echo "$target_json" | jq -r '.enabled // true')"
  retention_json="$(echo "$target_json" | jq -c '.retention // null')"
  [[ "$enabled" != "true" ]] && { echo "[SKIP] $name (disabled)" >&2; return 0; }

  local paths=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -e "$p" ]] && paths+=("$p") || echo "[WARN] Missing path: $p" >&2
  done < <(echo "$target_json" | jq -r '.locations[] | if type=="string" then . else .path end')
  [[ ${#paths[@]} -eq 0 ]] && { tg "⚠️ No valid paths for repo $name — skipping"; return 0; }

  local repo_url; repo_url="$(build_repo_url "$name")"
  ensure_repo "$repo_url"

  tg "📦 Backup → $name\n$(printf '• %s\n' "${paths[@]}")"
  local out rc
  if ! out="$(restic -r "$repo_url" "${RESTIC_AUTH_ARGS[@]}" backup "${paths[@]}" --host "$HOSTNAME_SHORT" 2>&1)"; then
    rc=$?
  else
    rc=0
  fi
  case "$rc" in
    0) tg "✅ Backup completed for $name\n$(echo "$out" | tail -n 30)";;
    3) tg "⚠️ Backup completed with unreadable files for $name (exit 3)\n$(echo "$out" | tail -n 60)";;
    *) tg "❌ Backup failed for $name (exit $rc)\n$(echo "$out" | tail -n 60)"; return "$rc";;
  esac

  run_retention "$repo_url" "$retention_json" || true

  if [[ "$(date +%u)" == "7" ]] && [[ "$(echo "$target_json" | jq -r '.checkWeekly // false')" == "true" ]]; then
    local ck; if ck="$(restic -r "$repo_url" "${RESTIC_AUTH_ARGS[@]}" check 2>&1)"; then
      tg "🧪 Check ok for $name"
    else
      tg "⚠️ Check failed for $name\n$(echo "$ck" | tail -n 60)"
    fi
  fi
}

main() {
  [[ -f "$TARGETS_FILE" ]] || { tg "❌ targets.json not found at $TARGETS_FILE"; exit 1; }
  jq empty "$TARGETS_FILE" >/dev/null || { tg "❌ targets.json is invalid JSON"; exit 1; }

  tg "🗄️ Backup started @ $(date '+%Y-%m-%d %H:%M:%S') on $HOSTNAME_SHORT"

  local total processed=0 failed=0
  total="$(jq 'length' "$TARGETS_FILE")"
  while IFS= read -r target; do
    if backup_target "$target"; then ((processed++)) || true; else ((failed++)) || true; fi
  done < <(jq -c '.[]' "$TARGETS_FILE")

  local end_ts; end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if (( failed == 0 )); then
    tg "✅ Backup finished @ $end_ts\nProcessed: $processed / $total\nFailed: $failed"
  else
    tg "❌ Backup finished with errors @ $end_ts\nProcessed: $processed / $total\nFailed: $failed"
  fi
}
main "$@"

