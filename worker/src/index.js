const STATE_KEY_PREFIX = "server:";

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      if (url.pathname === "/heartbeat" && request.method === "POST") {
        return handleHeartbeat(request, env);
      }

      if (url.pathname === "/status" && request.method === "GET") {
        return handleStatus(request, env);
      }

      //   if (url.pathname === "/debug" && request.method === "GET") {
      //     return handleDebug(env);
      //   }

      if (url.pathname === "/event" && request.method === "POST") {
        return handleEvent(request, env);
      }

      return new Response("Power monitor worker is running", {
        status: 200,
        headers: { "content-type": "text/plain" },
      });
    } catch (error) {
      return jsonResponse(
        {
          ok: false,
          error: "Worker exception",
          message: error.message,
          stack: error.stack,
        },
        500,
      );
    }
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      checkServer(env).catch((error) => {
        console.error("Scheduled check failed:", error);
      }),
    );
  },
};

// async function handleDebug(env) {
//   return jsonResponse({
//     ok: true,
//     checks: {
//       POWER_KV: !!env.POWER_KV,
//       TELEGRAM_BOT_TOKEN: !!env.TELEGRAM_BOT_TOKEN,
//       TELEGRAM_CHAT_ID: !!env.TELEGRAM_CHAT_ID,
//       HEARTBEAT_SECRET: !!env.HEARTBEAT_SECRET,
//       SERVER_ID: env.SERVER_ID || null,
//       SERVER_NAME: env.SERVER_NAME || null,
//       THRESHOLD_SECONDS: env.THRESHOLD_SECONDS || null,
//     },
//   });
// }

async function handleHeartbeat(request, env) {
  validateEnv(env);

  const secret = request.headers.get("x-heartbeat-secret");

  if (!secret || secret !== env.HEARTBEAT_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }

  const now = Date.now();
  const serverId = env.SERVER_ID || "home-server";
  const serverName = env.SERVER_NAME || serverId;

  let body = {};
  try {
    body = await request.json();
  } catch (_) {
    body = {};
  }

  const previousState = await getState(env, serverId);

  const newState = {
    serverId,
    serverName,
    status: "online",
    lastSeen: now,
    lastSeenText: formatTime(now, env),
    bootId: body.bootId || null,
    localServerName: body.server || null,
  };

  await putState(env, serverId, newState);

  if (previousState && previousState.status === "offline") {
    const downSince = previousState.downSince || previousState.lastSeen;
    const downtime = downSince ? formatDuration(now - downSince) : "unknown";

    await sendTelegram(
      env,
      `✅ ${serverName} is back online\n\n` +
        `Time: ${formatTime(now)}\n` +
        `Approx downtime: ${downtime}`,
    );
  }

  return jsonResponse({
    ok: true,
    status: "online",
    serverName,
    time: formatTime(now, env),
  });
}

async function handleEvent(request, env) {
  validateEnv(env);

  const secret = request.headers.get("x-heartbeat-secret");

  if (!secret || secret !== env.HEARTBEAT_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }

  let body = {};
  try {
    body = await request.json();
  } catch (_) {
    body = {};
  }

  const serverId = body.serverId || env.SERVER_ID || "home-server";
  const serverName = body.serverName || env.SERVER_NAME || serverId;
  const eventType = body.eventType || "unknown";
  const now = Date.now();

  if (eventType === "container_started") {
    await sendTelegram(
      env,
      `🚀 CF Edge Watcher Started\n\n` +
        `Server: ${serverName}\n` +
        `Server ID: ${serverId}\n` +
        `Time: ${formatTime(now, env)}`
    );
  }

  if (eventType === "container_stopped") {
    await sendTelegram(
      env,
      `🛑 CF Edge Watcher Stopped\n\n` +
        `Server: ${serverName}\n` +
        `Server ID: ${serverId}\n` +
        `Time: ${formatTime(now, env)}`
    );
  }

  return jsonResponse({
    ok: true,
    eventType,
    serverId,
    serverName,
    time: formatTime(now, env),
  });
}

async function handleStatus(request, env) {
  validateEnv(env);

  const serverId = env.SERVER_ID || "home-server";
  const state = await getState(env, serverId);

  if (!state) {
    return jsonResponse({
      status: "unknown",
      message: "No heartbeat received yet",
    });
  }

  const now = Date.now();
  const ageSeconds = Math.floor((now - state.lastSeen) / 1000);

  return jsonResponse({
    ...state,
    heartbeatAgeSeconds: ageSeconds,
    checkedAt: formatTime(now, env),
  });
}

async function checkServer(env) {
  validateEnv(env);

  const serverId = env.SERVER_ID || "home-server";
  const serverName = env.SERVER_NAME || serverId;
  const thresholdSeconds = Number(env.THRESHOLD_SECONDS || 180);
  const now = Date.now();

  const state = await getState(env, serverId);

  if (!state || !state.lastSeen) {
    return;
  }

  const ageSeconds = Math.floor((now - state.lastSeen) / 1000);

  if (state.status === "online" && ageSeconds > thresholdSeconds) {
    const offlineState = {
      ...state,
      status: "offline",
      downSince: state.lastSeen,
      downSinceText: formatTime(state.lastSeen, env),
      detectedAt: now,
      detectedAtText: formatTime(now, env),
    };

    await putState(env, serverId, offlineState);

    await sendTelegram(
      env,
      `⚠️ ${serverName} may be DOWN / power may be cut\n\n` +
        `Last heartbeat: ${formatTime(state.lastSeen, env)}\n` +
        `Detected at: ${formatTime(now, env)}\n` +
        `No heartbeat for: ${ageSeconds} seconds`,
    );
  }
}

function validateEnv(env) {
  const missing = [];

  if (!env.POWER_KV) missing.push("POWER_KV KV binding");
  if (!env.HEARTBEAT_SECRET) missing.push("HEARTBEAT_SECRET");
  if (!env.TELEGRAM_BOT_TOKEN) missing.push("TELEGRAM_BOT_TOKEN");
  if (!env.TELEGRAM_CHAT_ID) missing.push("TELEGRAM_CHAT_ID");

  if (missing.length > 0) {
    throw new Error(`Missing configuration: ${missing.join(", ")}`);
  }
}

async function getState(env, serverId) {
  const value = await env.POWER_KV.get(STATE_KEY_PREFIX + serverId);
  return value ? JSON.parse(value) : null;
}

async function putState(env, serverId, state) {
  await env.POWER_KV.put(STATE_KEY_PREFIX + serverId, JSON.stringify(state));
}

async function sendTelegram(env, text) {
  const telegramUrl = `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`;

  const response = await fetch(telegramUrl, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify({
      chat_id: env.TELEGRAM_CHAT_ID,
      text,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Telegram sendMessage failed: ${errorText}`);
  }
}

function formatTime(ms, env) {
  const timeZone = env.TIME_ZONE || "Asia/Kolkata";

  try {
    return new Date(ms).toLocaleString("en-US", {
      timeZone,
      hour12: true,
      year: "numeric",
      month: "short",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  } catch (_) {
    return new Date(ms).toISOString();
  }
}

function formatDuration(ms) {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;

  if (minutes < 60) {
    return `${minutes} min ${seconds} sec`;
  }

  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;

  return `${hours} hr ${remainingMinutes} min`;
}

function jsonResponse(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      "content-type": "application/json",
    },
  });
}