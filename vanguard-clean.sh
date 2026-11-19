#!/bin/bash
# VanguardVPS — volume cleaner: keep the 500MB /root volume lean.
# Runs forever, cleaning every CLEAN_INTERVAL seconds (default 1800 = 30 min).
# Only removes regenerable cache/temp files. NEVER touches:
#   /root/.9router/db, auth, jwt-secret, machine-id, second-brain.json,
#   model-monitor.json, model-catalog*.json, /root/src/9router-backup.json,
#   /root/src/.git, /root/.ssh
# Logs to /var/log/vanguard-clean.log (overlay disk, not the volume).
# Override: CLEAN_INTERVAL=900 /usr/local/bin/vanguard-clean

CLEAN_INTERVAL="${CLEAN_INTERVAL:-1800}"
VOLUME="${VOLUME:-/root}"
LOG="${CLEAN_LOG:-/var/log/vanguard-clean.log}"

log() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] vanguard-clean: $*"
  echo "$line" >> "$LOG" 2>/dev/null || echo "$line"
}

clean_once() {
  # npm cache (defensive: NPM_CONFIG_CACHE should already point it at /tmp,
  # but if anything recreated it on the volume, clear it)
  [ -d "$VOLUME/.npm" ] && rm -rf -- "$VOLUME/.npm" 2>/dev/null
  # generic caches
  [ -d "$VOLUME/.cache" ] && rm -rf -- "$VOLUME/.cache" 2>/dev/null
  # temp files under the 9Router data dir (failed/incomplete writes)
  find "$VOLUME/.9router" -maxdepth 1 -name '*.tmp' -delete 2>/dev/null
  # old 9Router logs (keep the last 7 days)
  find "$VOLUME/.9router/logs" -type f -mtime +7 -delete 2>/dev/null
  local used
  used=$(df -P "$VOLUME" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
  log "cleaned; volume use ${used:-?}%"
  if [ -n "$used" ] && [ "$used" -ge 80 ]; then
    log "WARNING: volume use ${used}% — still above 80% after cleaning"
  fi
}

log "started (interval ${CLEAN_INTERVAL}s, volume $VOLUME)"
clean_once
while true; do
  sleep "$CLEAN_INTERVAL"
  clean_once
done
