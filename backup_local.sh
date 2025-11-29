#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-"$SCRIPT_DIR/.env"}"
TARGETS_FILE="${TARGETS_FILE:-"$SCRIPT_DIR/targets.json"}"
HOSTNAME_SHORT="$(hostname -s || hostname || echo unknown)"

if [[ -f "$ENV_FILE" ]]; then set -a; source "$ENV_FILE"; set +a; fi

: "${LOCAL_BACKUP_ROOT:?LOCAL_BACKUP_ROOT is required}"

command -v rsync >/dev/null || { echo "[ERROR] rsync not found"; exit 1; }
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

# Prune files older than 60 days that no longer exist on source
prune_old_backups() {
  local target_dir="$1"
  local max_age_days=60

  if [[ ! -d "$target_dir" ]]; then
    return 0
  fi

  local deleted_count=0
  while IFS= read -r backup_file; do
    [[ -z "$backup_file" ]] && continue

    # Check if file exists in any of the source locations
    local found=0
    for source_path in "${paths[@]}"; do
      local rel_path="${backup_file#"$target_dir/"}"
      local source_file="${source_path}/${rel_path}"

      if [[ -e "$source_file" ]]; then
        found=1
        break
      fi
    done

    if (( found == 0 )); then
      rm -f "$backup_file"
      ((deleted_count++)) || true
    fi
  done < <(find "$target_dir" -type f -mtime +$max_age_days)

  echo "$deleted_count"
}

backup_target() {
  local target_json="$1"
  local name enabled local_enabled
  name="$(echo "$target_json"    | jq -r '.name')"
  enabled="$(echo "$target_json" | jq -r '.enabled // true')"
  local_enabled="$(echo "$target_json" | jq -r '.local // false')"

  [[ "$enabled" != "true" ]] && { echo "[SKIP] $name (disabled)" >&2; return 0; }
  [[ "$local_enabled" != "true" ]] && { echo "[SKIP] $name (local backup disabled)" >&2; return 0; }

  local paths=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -e "$p" ]] && paths+=("$p") || echo "[WARN] Missing path: $p" >&2
  done < <(echo "$target_json" | jq -r '.locations[] | if type=="string" then . else .path end')
  [[ ${#paths[@]} -eq 0 ]] && { tg "⚠️ No valid paths for local backup $name — skipping"; return 0; }

  # Just in case
  mkdir -p "$LOCAL_BACKUP_ROOT"
  local target_backup_dir="${LOCAL_BACKUP_ROOT}/${name}"
  mkdir -p "$target_backup_dir"

   tg "📦 Local Backup → $name
$(printf '• %s\n' "${paths[@]}")"

   local out rc=0

   if ! out="$(rsync -av --delete "${paths[@]}" "${target_backup_dir}/" 2>&1)"; then
     rc=$?
   fi

   case "$rc" in
     0) tg "✅ Local backup completed for $name
$(echo "$out" | tail -n 20)";;
     *) tg "❌ Local backup failed for $name (exit $rc)
$(echo "$out" | tail -n 30)"; return "$rc";;
   esac

   tg "🧹 Pruning files older than 60 days that don't exist on source for $name"
   local deleted_count
   deleted_count="$(prune_old_backups "$target_backup_dir")"
   tg "ℹ️ Deleted $deleted_count old files from backup of $name"
}

main() {
  [[ -f "$TARGETS_FILE" ]] || { tg "❌ targets.json not found at $TARGETS_FILE"; exit 1; }
  jq empty "$TARGETS_FILE" >/dev/null || { tg "❌ targets.json is invalid JSON"; exit 1; }

  tg "🗄️ Local backup started @ $(date '+%Y-%m-%d %H:%M:%S') on $HOSTNAME_SHORT
📂 Backup root: $LOCAL_BACKUP_ROOT"

  local total processed=0 failed=0
  total="$(jq 'length' "$TARGETS_FILE")"
  while IFS= read -r target; do
    if backup_target "$target"; then ((processed++)) || true; else ((failed++)) || true; fi
  done < <(jq -c '.[]' "$TARGETS_FILE")

  local end_ts; end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if (( failed == 0 )); then
    tg "✅ Local backup finished @ $end_ts
Processed: $processed / $total
Failed: $failed"
  else
    tg "❌ Local backup finished with errors @ $end_ts
Processed: $processed / $total
Failed: $failed"
  fi
}
main "$@"
