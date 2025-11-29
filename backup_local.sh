#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

: "${LOCAL_BACKUP_ROOT:?LOCAL_BACKUP_ROOT is required}"

validate_command rsync
validate_command jq

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
   [[ ${#paths[@]} -eq 0 ]] && { tg "[WARN] No valid paths for local backup $name -- skipping"; return 0; }

  # Just in case
  mkdir -p "$LOCAL_BACKUP_ROOT"
  local target_backup_dir="${LOCAL_BACKUP_ROOT}/${name}"
  mkdir -p "$target_backup_dir"

    tg "[BACKUP] Local backup -> $name
$(printf '  %s\n' "${paths[@]}")"

   local out rc=0

   if ! out="$(rsync -av --delete "${paths[@]}" "${target_backup_dir}/" 2>&1)"; then
     rc=$?
   fi

    case "$rc" in
      0) tg "[OK] Local backup completed for $name
$(echo "$out" | tail -n 20)";;
      *) tg "[ERROR] Local backup failed for $name (exit $rc)
$(echo "$out" | tail -n 30)"; return "$rc";;
    esac

    tg "[OK] Pruning files older than 60 days that don't exist on source for $name"
    local deleted_count
    deleted_count="$(prune_old_backups "$target_backup_dir")"
    tg "[INFO] Deleted $deleted_count old files from backup of $name"
}

main() {
   validate_targets_file

   local start_ts start_epoch
   start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
   start_epoch="$(date '+%s')"
   tg "[START] Local backup started @ $start_ts on $HOSTNAME_SHORT
[INFO] Backup root: $LOCAL_BACKUP_ROOT"

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

   print_final_summary "$end_ts" "$processed" "$total" "$failed" "$elapsed_time" "Local backup"
}
main "$@"
