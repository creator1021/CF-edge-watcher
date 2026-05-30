#!/bin/sh
set -eu

LOG_DIR="${LOG_DIR:-/app/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/cf-edge-watcher.log}"
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"
LOG_MAX_FILES="${LOG_MAX_FILES:-2}"

mkdir -p "$LOG_DIR"

rotate_logs_if_needed() {
  if [ ! -f "$LOG_FILE" ]; then
    return
  fi

  current_size_bytes="$(wc -c < "$LOG_FILE" | tr -d ' ')"
  max_size_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))

  if [ "$current_size_bytes" -lt "$max_size_bytes" ]; then
    return
  fi

  i="$LOG_MAX_FILES"

  while [ "$i" -ge 1 ]; do
    prev=$((i - 1))

    if [ "$prev" -eq 0 ]; then
      src="$LOG_FILE"
    else
      src="$LOG_FILE.$prev"
    fi

    dest="$LOG_FILE.$i"

    if [ -f "$src" ]; then
      mv "$src" "$dest"
    fi

    i=$((i - 1))
  done

  : > "$LOG_FILE"
}

log() {
  rotate_logs_if_needed
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

required_var() {
  var_name="$1"
  eval "value=\${$var_name:-}"

  if [ -z "$value" ]; then
    log "ERROR: Missing required environment variable: $var_name"
    exit 1
  fi
}

required_var "WORKER_URL"
required_var "HEARTBEAT_SECRET"
required_var "SERVER_ID"
required_var "SERVER_NAME"

INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || hostname)-$(date +%s)"

log "CF Edge Watcher container started"
log "Server ID: $SERVER_ID"
log "Server name: $SERVER_NAME"
log "Worker URL: $WORKER_URL"
log "Interval seconds: $INTERVAL_SECONDS"
log "Log file: $LOG_FILE"
log "Log max size MB: $LOG_MAX_SIZE_MB"
log "Log max files: $LOG_MAX_FILES"

while true
do
  if curl -fsS -X POST "$WORKER_URL/heartbeat" \
    -H "content-type: application/json" \
    -H "x-heartbeat-secret: $HEARTBEAT_SECRET" \
    -d "{\"serverId\":\"$SERVER_ID\",\"serverName\":\"$SERVER_NAME\",\"bootId\":\"$BOOT_ID\"}" >/dev/null
  then
    log "Heartbeat sent successfully"
  else
    log "ERROR: Heartbeat failed"
  fi

  sleep "$INTERVAL_SECONDS"
done