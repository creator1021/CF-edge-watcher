#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/.env}"

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

WORKER_DIR="$ROOT_DIR/worker"
LOCAL_DIR="$ROOT_DIR/local"

mkdir -p "$WORKER_DIR"
mkdir -p "$LOCAL_DIR"

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

npm install

cat > wrangler.toml <<EOF
name = "$WORKER_NAME"
main = "src/index.js"
compatibility_date = "2026-05-28"

[vars]
SERVER_ID = "$SERVER_ID"
SERVER_NAME = "$SERVER_NAME"
THRESHOLD_SECONDS = "$THRESHOLD_SECONDS"

[triggers]
crons = ["$CRON_EXPRESSION"]
EOF

echo "Checking KV namespace..."

KV_LIST="$(npx wrangler kv namespace list --config wrangler.toml || echo "[]")"

KV_ID="$(
  printf '%s' "$KV_LIST" | node -e '
    const fs = require("fs");
    const input = fs.readFileSync(0, "utf8");
    const title = process.env.KV_NAMESPACE_TITLE;

    try {
      const arr = JSON.parse(input);
      const hit = arr.find(x => x.title === title);
      if (hit) process.stdout.write(hit.id);
    } catch (e) {}
  '
)"

if [ -z "$KV_ID" ]; then
  echo "Creating KV namespace: $KV_NAMESPACE_TITLE"

  CREATE_OUTPUT="$(
    npx wrangler kv namespace create "$KV_NAMESPACE_TITLE" \
      --binding "$KV_BINDING" \
      --config wrangler.toml 2>&1
  )"

  echo "$CREATE_OUTPUT"

  KV_ID="$(
    printf '%s' "$CREATE_OUTPUT" | grep -Eo 'id = "[^"]+"' | head -1 | cut -d '"' -f 2 || true
  )"

  if [ -z "$KV_ID" ]; then
    echo "Could not parse KV ID from create output. Trying namespace list again..."

    KV_LIST="$(npx wrangler kv namespace list --config wrangler.toml)"
    KV_ID="$(
      printf '%s' "$KV_LIST" | node -e '
        const fs = require("fs");
        const input = fs.readFileSync(0, "utf8");
        const title = process.env.KV_NAMESPACE_TITLE;

        try {
          const arr = JSON.parse(input);
          const hit = arr.find(x => x.title === title);
          if (hit) process.stdout.write(hit.id);
        } catch (e) {}
      '
    )"
  fi
fi

if [ -z "$KV_ID" ]; then
  echo "ERROR: KV namespace ID could not be found."
  exit 1
fi

cat >> wrangler.toml <<EOF

[[kv_namespaces]]
binding = "$KV_BINDING"
id = "$KV_ID"
EOF

echo "Generated worker/wrangler.toml with KV binding: $KV_BINDING"

SECRET_FILE="$(mktemp)"

cat > "$SECRET_FILE" <<EOF
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
HEARTBEAT_SECRET="$HEARTBEAT_SECRET"
EOF

echo "Deploying Cloudflare Worker..."

DEPLOY_OUTPUT="$(
  npx wrangler deploy \
    --config wrangler.toml \
    --secrets-file "$SECRET_FILE" 2>&1 | tee /dev/stderr
)"

rm -f "$SECRET_FILE"

WORKER_URL="$(
  printf '%s' "$DEPLOY_OUTPUT" | grep -Eo 'https://[^[:space:]]+\.workers\.dev' | tail -1 || true
)"

cat > "$LOCAL_DIR/.env" <<EOF
WORKER_URL="$WORKER_URL"
HEARTBEAT_SECRET="$HEARTBEAT_SECRET"
SERVER_ID="$SERVER_ID"
SERVER_NAME="$SERVER_NAME"
INTERVAL_SECONDS="$INTERVAL_SECONDS"
EOF

echo ""
echo "Bootstrap completed."
echo ""
echo "KV namespace ID: $KV_ID"
echo "Worker URL: ${WORKER_URL:-not detected from output}"
echo ""
echo "Generated local Docker env file:"
echo "local/.env"
echo ""

if [ -z "$WORKER_URL" ]; then
  echo "WARNING: Worker URL was not auto-detected."
  echo "Open Cloudflare Worker dashboard, copy the workers.dev URL, and update local/.env manually."
fi
