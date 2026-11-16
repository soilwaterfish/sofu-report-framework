#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-frequent}"
case "$mode" in frequent|full) ;; *) echo "Usage: $0 [frequent|full]" >&2; exit 2 ;; esac
mkdir -p "$repo_dir/logs"
cd "$repo_dir"
exec 9>"$repo_dir/logs/scheduled-refresh.lock"
if ! /usr/bin/flock -n 9; then
  printf '%s SOFU %s skipped: scheduled refresh already running\n' "$(date --iso-8601=seconds)" "$mode"
  exit 0
fi
printf '%s SOFU %s started\n' "$(date --iso-8601=seconds)" "$mode"
status=0
target="docker-run-frequent"
if [[ "$mode" == full ]]; then target="docker-run-scheduled"; fi
if [[ "${SOFU_CRON_DRY_RUN:-0}" == 1 ]]; then
  /usr/bin/make --dry-run "$target" || status=$?
else
  /usr/bin/make "$target" || status=$?
fi
printf '%s SOFU %s finished status=%s\n' "$(date --iso-8601=seconds)" "$mode" "$status"
exit "$status"
