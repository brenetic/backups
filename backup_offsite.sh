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
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"

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

repo_lock_status() {
  local repo_url="$1"
  local ids
  if ! ids="$(restic -r "$repo_url" list locks --no-lock 2>/dev/null | awk '{print $1}')" ; then
    echo "free"; return 0
  fi
  [[ -z "$ids" ]] && { echo "free"; return 0; }

  local recent=0
  for id in $ids; do
    local ts
    ts="$(restic -r "$repo_url" cat lock "$id" --json 2>/dev/null | jq -r '.time // empty')" || ts=""
    if [[ -z "$ts" ]]; then recent=1; break; fi
    if jq -e -n --arg t "$ts" 'now - ($t|fromdateiso8601) < 1800' >/dev/null; then
      recent=1; break
    fi
  done
  (( recent == 1 )) && echo "active" || echo "stale"
}

ensure_repo() {
  local repo_url="$1"
  if restic -r "$repo_url" cat config >/dev/null 2>&1; then
    return 0
  fi
  tg "ℹ️ Initialising repo → $repo_url"
  restic -r "$repo_url" init >/tmp/restic_init.log 2>&1 || {
    if grep -q "already initialized" /tmp/restic_init.log 2>/dev/null; then
      tg "ℹ️ Repo already initialized → $repo_url"
      return 0
    fi
    tg "❌ Repo init failed for $repo_url
$(tail -n 60 /tmp/restic_init.log || true)"; return 1; }
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
  if ! out="$(restic -r "$repo_url" forget --prune "${args[@]}" 2>&1)"; then
    rc=$?; tg "⚠️ Retention failed for $repo_url (exit $rc)
$(echo "$out" | tail -n 60)"; return $rc
  fi
  tg "🧹 Retention ok for $repo_url
$(echo "$out" | tail -n 30)"
}

backup_target() {
  local target_json="$1"
  local name enabled offsite_enabled retention_json
  name="$(echo "$target_json"    | jq -r '.name')"
  enabled="$(echo "$target_json" | jq -r '.enabled // true')"
  offsite_enabled="$(echo "$target_json" | jq -r '.offsite // false')"
  retention_json="$(echo "$target_json" | jq -c '.retention // null')"
  [[ "$enabled" != "true" ]] && { echo "[SKIP] $name (disabled)" >&2; return 0; }
  [[ "$offsite_enabled" != "true" ]] && { echo "[SKIP] $name (offsite backup disabled)" >&2; return 0; }

  local paths=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -e "$p" ]] && paths+=("$p") || echo "[WARN] Missing path: $p" >&2
  done < <(echo "$target_json" | jq -r '.locations[] | if type=="string" then . else .path end')
  [[ ${#paths[@]} -eq 0 ]] && { tg "⚠️ No valid paths for repo $name — skipping"; return 0; }

  local repo_url; repo_url="$(build_repo_url "$name")"
  ensure_repo "$repo_url"

  case "$(repo_lock_status "$repo_url")" in
    active)
      tg "🔒 Repo $name is currently locked (active). Skipping this repo."
      return 0
      ;;
    stale)
      tg "🧹 Stale locks detected for $name — attempting unlock"
      restic -r "$repo_url" unlock >/dev/null 2>&1 || true
      if [[ "$(repo_lock_status "$repo_url")" != "free" ]]; then
        tg "🔒 Repo $name still locked after unlock attempt. Skipping."
        return 0
      fi
      ;;
    free) : ;;
  esac

  tg "📦 Backup → $name
$(printf '• %s\n' "${paths[@]}")"
  local out rc
  if ! out="$(restic -r "$repo_url" backup "${paths[@]}" --host "$HOSTNAME_SHORT" 2>&1)"; then
    rc=$?
  else
    rc=0
  fi
  case "$rc" in
    0) tg "✅ Backup completed for $name
$(echo "$out" | tail -n 30)";;
    3) tg "⚠️ Backup completed with unreadable files for $name (exit 3)
$(echo "$out" | tail -n 60)";;
    *) tg "❌ Backup failed for $name (exit $rc)
$(echo "$out" | tail -n 60)"; return "$rc";;
  esac

  run_retention "$repo_url" "$retention_json" || true

  if [[ "$(date +%u)" == "7" ]] && [[ "$(echo "$target_json" | jq -r '.checkWeekly // false')" == "true" ]]; then
    local ck; if ck="$(restic -r "$repo_url" check 2>&1)"; then
      tg "🧪 Check ok for $name"
    else
      tg "⚠️ Check failed for $name
$(echo "$ck" | tail -n 60)"
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
    tg "✅ Backup finished @ $end_ts
Processed: $processed / $total
Failed: $failed"
  else
    tg "❌ Backup finished with errors @ $end_ts
Processed: $processed / $total
Failed: $failed"
  fi
}
main "$@"

