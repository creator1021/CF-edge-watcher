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

send_worker_event() {
  event_type="$1"

  if curl -fsS -X POST "$WORKER_URL/event" \
    -H "content-type: application/json" \
    -H "x-heartbeat-secret: $HEARTBEAT_SECRET" \
    -d "{\"eventType\":\"$event_type\",\"serverId\":\"$SERVER_ID\",\"serverName\":\"$SERVER_NAME\",\"bootId\":\"$BOOT_ID\"}" \
    >/dev/null
  then
    log "Worker event sent: $event_type"
  else
    log "ERROR: Failed to send worker event: $event_type"
  fi
}

SLEEP_PID=""

on_shutdown() {
  log "Container stop signal received"

  if [ -n "${SLEEP_PID:-}" ]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi

  send_worker_event "container_stopped"
  log "Container stopped notification sent"
  exit 0
}

trap on_shutdown TERM INT

print_banner() {
  log "  ____ _____   _____    _           "
  log " / ___|  ___| | ____|__| | __ _  ___"
  log "| |   | |_    |  _| / _\` |/ _\` |/ _ \\"
  log "| |___|  _|   | |__| (_| | (_| |  __/"
  log " \____|_|     |_____\__,_|\__, |\___|"
  log "                           |___/     "
  log ""
  log "__        __    _       _               "
  log "\ \      / /_ _| |_ ___| |__   ___ _ __ "
  log " \ \ /\ / / _\` | __/ __| '_ \ / _ \ '__|"
  log "  \ V  V / (_| | || (__| | | |  __/ |   "
  log "   \_/\_/ \__,_|\__\___|_| |_|\___|_|   "
}
print_banner
log " "

log "CF Edge Watcher container started"
log "Server ID: $SERVER_ID"
log "Server name: $SERVER_NAME"
log "Worker URL: $WORKER_URL"
log "Interval seconds: $INTERVAL_SECONDS"
log "Log file: $LOG_FILE"
log "Log max size MB: $LOG_MAX_SIZE_MB"
log "Log max files: $LOG_MAX_FILES"
send_worker_event "container_started"
log "Container started notification sent"


HEARTBEAT_COUNT=0

while true
do
  HEARTBEAT_COUNT=$((HEARTBEAT_COUNT + 1))

  RESPONSE_TIME="$(
    curl -o /dev/null -sS -w "%{time_total}" -X POST "$WORKER_URL/heartbeat" \
      -H "content-type: application/json" \
      -H "x-heartbeat-secret: $HEARTBEAT_SECRET" \
      -d "{\"serverId\":\"$SERVER_ID\",\"serverName\":\"$SERVER_NAME\",\"bootId\":\"$BOOT_ID\"}" \
      2>/tmp/cf-edge-watcher-curl-error
  )"

  CURL_EXIT_CODE=$?

  if [ "$CURL_EXIT_CODE" -eq 0 ]; then
    RESPONSE_TIME_MS="$(
      awk "BEGIN { printf \"%.0f\", $RESPONSE_TIME * 1000 }"
    )"

    log "Heartbeat #$HEARTBEAT_COUNT successful (${RESPONSE_TIME_MS} ms)"
  else
    CURL_ERROR="$(cat /tmp/cf-edge-watcher-curl-error 2>/dev/null || true)"
    log "ERROR: Heartbeat #$HEARTBEAT_COUNT failed${CURL_ERROR:+ - $CURL_ERROR}"
  fi

 sleep "$INTERVAL_SECONDS" &
  SLEEP_PID=$!

  wait "$SLEEP_PID" || true
done