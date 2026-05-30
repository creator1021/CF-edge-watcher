#!/bin/sh

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || hostname)-$(date +%s)"

echo "Heartbeat container started"
echo "Worker URL: $WORKER_URL"
echo "Server name: $SERVER_NAME"

while true
do
  curl -sS -X POST "$WORKER_URL/heartbeat" \
    -H "content-type: application/json" \
    -H "x-heartbeat-secret: $HEARTBEAT_SECRET" \
    -d "{\"server\":\"$SERVER_NAME\",\"bootId\":\"$BOOT_ID\"}" \
    || echo "Heartbeat failed at $(date)"

  sleep "${INTERVAL_SECONDS:-60}"
done