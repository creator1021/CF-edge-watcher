#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/.env}"
CF_API_BASE="https://api.cloudflare.com/client/v4"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found."
  echo "Create it first: cp .env.example .env"
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

required() {
  local name="$1"
  local value="${!name:-}"

  if [ -z "$value" ]; then
    echo "ERROR: Missing required value: $name"
    exit 1
  fi
}

required "CLOUDFLARE_ACCOUNT_ID"
required "CLOUDFLARE_API_TOKEN"
required "WORKER_NAME"
required "KV_BINDING"
required "KV_NAMESPACE_TITLE"
required "SERVER_ID"
required "SERVER_NAME"
required "THRESHOLD_SECONDS"
required "CRON_EXPRESSION"
required "TELEGRAM_BOT_TOKEN"
required "TELEGRAM_CHAT_ID"
required "HEARTBEAT_SECRET"
required "INTERVAL_SECONDS"

export CLOUDFLARE_ACCOUNT_ID
export CLOUDFLARE_API_TOKEN

TIME_ZONE="${TIME_ZONE:-Asia/Kolkata}"
LOG_DIR="${LOG_DIR:-/app/logs}"
LOG_FILE="${LOG_FILE:-/app/logs/cf-edge-watcher.log}"
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"
LOG_MAX_FILES="${LOG_MAX_FILES:-2}"

WORKER_DIR="$ROOT_DIR/worker"
LOCAL_DIR="$ROOT_DIR/local"

mkdir -p "$WORKER_DIR"
mkdir -p "$LOCAL_DIR"
mkdir -p "$WORKER_DIR/src"

cd "$WORKER_DIR"

if [ ! -f "package.json" ]; then
  cat > package.json <<EOF
{
  "name": "$WORKER_NAME",
  "version": "1.0.0",
  "private": true,
  "devDependencies": {
    "wrangler": "latest"
  },
  "scripts": {
    "deploy": "wrangler deploy"
  }
}
EOF
fi

echo "Installing/updating Wrangler..."
npm install

write_wrangler_config() {
  local kv_id="${1:-}"

  cat > wrangler.toml <<EOF
name = "$WORKER_NAME"
main = "src/index.js"
compatibility_date = "2026-05-28"
workers_dev = true

[vars]
SERVER_ID = "$SERVER_ID"
SERVER_NAME = "$SERVER_NAME"
THRESHOLD_SECONDS = "$THRESHOLD_SECONDS"
TIME_ZONE = "$TIME_ZONE"

[triggers]
crons = ["$CRON_EXPRESSION"]
EOF

  if [ -n "$kv_id" ]; then
    cat >> wrangler.toml <<EOF

[[kv_namespaces]]
binding = "$KV_BINDING"
id = "$kv_id"
EOF
  fi
}

cf_api_get() {
  local url="$1"

  curl -fsS \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$url"
}

cf_api_post() {
  local url="$1"
  local data="$2"

  curl -fsS \
    -X POST \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$data" \
    "$url"
}

find_kv_id_by_api() {
  local page=1
  local total_pages=1
  local response
  local found_id

  while [ "$page" -le "$total_pages" ]; do
    response="$(
      cf_api_get "$CF_API_BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/storage/kv/namespaces?per_page=100&page=$page"
    )"

    found_id="$(
      printf '%s' "$response" | node -e '
        const fs = require("fs");
        const input = fs.readFileSync(0, "utf8");
        const title = process.env.KV_NAMESPACE_TITLE;

        try {
          const json = JSON.parse(input);
          if (!json.success) process.exit(0);

          const hit = (json.result || []).find(ns => ns.title === title);
          if (hit && hit.id) process.stdout.write(hit.id);
        } catch (e) {}
      '
    )"

    if [ -n "$found_id" ]; then
      printf '%s' "$found_id"
      return 0
    fi

    total_pages="$(
      printf '%s' "$response" | node -e '
        const fs = require("fs");
        const input = fs.readFileSync(0, "utf8");

        try {
          const json = JSON.parse(input);
          const total = json.result_info && json.result_info.total_pages
            ? json.result_info.total_pages
            : 1;
          process.stdout.write(String(total));
        } catch (e) {
          process.stdout.write("1");
        }
      '
    )"

    page=$((page + 1))
  done
}

create_kv_by_api() {
  local response
  local namespace_title_escaped

  namespace_title_escaped="$(
    node -e 'process.stdout.write(JSON.stringify(process.env.KV_NAMESPACE_TITLE))'
  )"

  response="$(
    cf_api_post \
      "$CF_API_BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/storage/kv/namespaces" \
      "{\"title\":$namespace_title_escaped}"
  )"

  printf '%s' "$response" | node -e '
    const fs = require("fs");
    const input = fs.readFileSync(0, "utf8");

    try {
      const json = JSON.parse(input);

      if (json.success && json.result && json.result.id) {
        process.stdout.write(json.result.id);
      }
    } catch (e) {}
  '
}

write_wrangler_config ""

echo "Checking KV namespace by Cloudflare API: $KV_NAMESPACE_TITLE"

KV_ID="$(find_kv_id_by_api || true)"

if [ -n "$KV_ID" ]; then
  echo "Existing KV namespace found."
  echo "KV namespace title: $KV_NAMESPACE_TITLE"
  echo "KV namespace ID: $KV_ID"
else
  echo "KV namespace not found. Creating new KV namespace: $KV_NAMESPACE_TITLE"

  KV_ID="$(create_kv_by_api || true)"

  if [ -z "$KV_ID" ]; then
    echo "Create request did not return KV ID. Rechecking existing namespaces..."
    KV_ID="$(find_kv_id_by_api || true)"
  fi
fi

if [ -z "$KV_ID" ]; then
  echo "ERROR: KV namespace ID could not be found or created."
  echo "Check your Cloudflare API token permissions:"
  echo "- Workers KV Storage: Edit"
  echo "- Workers Scripts: Edit"
  exit 1
fi

write_wrangler_config "$KV_ID"

echo "Generated worker/wrangler.toml"
echo "Worker name: $WORKER_NAME"
echo "KV binding: $KV_BINDING"
echo "KV namespace title: $KV_NAMESPACE_TITLE"
echo "KV namespace ID: $KV_ID"

SECRET_FILE="$(mktemp)"
cleanup() {
  rm -f "$SECRET_FILE"
}
trap cleanup EXIT

cat > "$SECRET_FILE" <<EOF
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
HEARTBEAT_SECRET="$HEARTBEAT_SECRET"
EOF

echo "Deploying Cloudflare Worker..."
echo "If Worker '$WORKER_NAME' exists, Wrangler will update it."
echo "If Worker '$WORKER_NAME' does not exist, Wrangler will create it."

DEPLOY_OUTPUT="$(
  npx wrangler deploy \
    --config wrangler.toml \
    --secrets-file "$SECRET_FILE" 2>&1 | tee /dev/stderr
)"

WORKER_URL="$(
  printf '%s' "$DEPLOY_OUTPUT" | grep -Eo 'https://[^[:space:]]+\.workers\.dev' | tail -1 || true
)"

if [ -z "$WORKER_URL" ]; then
  WORKER_URL="https://${WORKER_NAME}.${CLOUDFLARE_ACCOUNT_ID}.workers.dev"
fi

cat > "$LOCAL_DIR/.env" <<EOF
WORKER_URL="$WORKER_URL"
HEARTBEAT_SECRET="$HEARTBEAT_SECRET"
SERVER_ID="$SERVER_ID"
SERVER_NAME="$SERVER_NAME"
INTERVAL_SECONDS="$INTERVAL_SECONDS"
LOG_DIR="$LOG_DIR"
LOG_FILE="$LOG_FILE"
LOG_MAX_SIZE_MB="$LOG_MAX_SIZE_MB"
LOG_MAX_FILES="$LOG_MAX_FILES"
TZ="$TIME_ZONE"
EOF

echo ""
echo "Setup completed."
echo ""
echo "Worker name: $WORKER_NAME"
echo "KV namespace title: $KV_NAMESPACE_TITLE"
echo "KV namespace ID: $KV_ID"
echo "Worker URL: $WORKER_URL"
echo ""
echo "Generated files:"
echo "worker/wrangler.toml"
echo "local/.env"
echo ""