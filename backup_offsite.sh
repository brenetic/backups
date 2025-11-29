#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

: "${B2_BUCKET_NAME:?B2_BUCKET_NAME is required}"
: "${B2_ACCOUNT_ID:?B2_ACCOUNT_ID is required}"
: "${B2_ACCOUNT_KEY:?B2_ACCOUNT_KEY is required}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"

validate_command restic
validate_command jq
validate_command curl WARN

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
   tg "[INFO] Initialising repo -> $repo_url"
  restic -r "$repo_url" init >/tmp/restic_init.log 2>&1 || {
    if grep -q "already initialized" /tmp/restic_init.log 2>/dev/null; then
       tg "[INFO] Repo already initialized -> $repo_url"
      return 0
    fi
     tg "[ERROR] Repo init failed for $repo_url
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
     rc=$?; tg "[WARN] Retention failed for $repo_url (exit $rc)
$(echo "$out" | tail -n 60)"; return $rc
   fi
   tg "[OK] Retention ok for $repo_url
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
   [[ ${#paths[@]} -eq 0 ]] && { tg "[WARN] No valid paths for repo $name -- skipping"; return 0; }

  local repo_url; repo_url="$(build_repo_url "$name")"
  ensure_repo "$repo_url"

   case "$(repo_lock_status "$repo_url")" in
     active)
       tg "[LOCK] Repo $name is currently locked (active). Skipping this repo."
       return 0
       ;;
     stale)
       tg "[OK] Stale locks detected for $name -- attempting unlock"
       restic -r "$repo_url" unlock >/dev/null 2>&1 || true
       if [[ "$(repo_lock_status "$repo_url")" != "free" ]]; then
         tg "[LOCK] Repo $name still locked after unlock attempt. Skipping."
         return 0
       fi
       ;;
     free) : ;;
   esac

   tg "[BACKUP] Backup -> $name
$(printf '  %s\n' "${paths[@]}")"
  local out rc
  if ! out="$(restic -r "$repo_url" backup "${paths[@]}" --host "$HOSTNAME_SHORT" 2>&1)"; then
    rc=$?
  else
    rc=0
  fi
   case "$rc" in
     0) tg "[OK] Backup completed for $name
$(echo "$out" | tail -n 30)";;
     3) tg "[WARN] Backup completed with unreadable files for $name (exit 3)
$(echo "$out" | tail -n 60)";;
     *) tg "[ERROR] Backup failed for $name (exit $rc)
$(echo "$out" | tail -n 60)"; return "$rc";;
   esac

  run_retention "$repo_url" "$retention_json" || true

  if [[ "$(date +%u)" == "7" ]] && [[ "$(echo "$target_json" | jq -r '.checkWeekly // false')" == "true" ]]; then
     local ck; if ck="$(restic -r "$repo_url" check 2>&1)"; then
       tg "[OK] Check ok for $name"
     else
       tg "[WARN] Check failed for $name
$(echo "$ck" | tail -n 60)"
    fi
  fi
}

main() {
   validate_targets_file

   local start_ts start_epoch
   start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
   start_epoch="$(date '+%s')"
   tg "[START] Backup started @ $start_ts on $HOSTNAME_SHORT"

   local total processed=0 failed=0
   total="$(jq 'length' "$TARGETS_FILE")"
   while IFS= read -r target; do
     if backup_target "$target"; then ((processed++)) || true; else ((failed++)) || true; fi
   done < <(jq -c '.[]' "$TARGETS_FILE")

   local end_ts end_epoch
   end_ts="$(date '+%Y-%m-%d %H:%M:%S')"
   end_epoch="$(date '+%s')"
   local elapsed_time
   elapsed_time="$(calculate_elapsed_time "$start_epoch" "$end_epoch")"
   
   print_final_summary "$end_ts" "$processed" "$total" "$failed" "$elapsed_time" "Backup"
}
main "$@"

