const http = require('http');

const TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const OAUTH_BETA = 'oauth-2025-04-20';
const USER_AGENT = 'claude-lametric/1.0';
const PORT      = process.env.PORT || 3000;

// Icon IDs — customize at https://developer.lametric.com/icons
const ICON_SESSION = 'i16776';
const ICON_WEEKLY  = 'i2867';
const ICON_CREDITS = 'i1334';
const ICON_ERROR   = 'i9182';

const REFRESH_TOKEN = process.env.CLAUDE_REFRESH_TOKEN;
if (!REFRESH_TOKEN) {
  console.error('[claude-lametric] CLAUDE_REFRESH_TOKEN env var is not set');
  process.exit(1);
}

let cachedAccessToken = null;
let tokenExpiresAt    = 0;

async function getAccessToken() {
  if (cachedAccessToken && Date.now() < tokenExpiresAt - 60_000) {
    return cachedAccessToken;
  }

  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': USER_AGENT },
    body: JSON.stringify({
      grant_type: 'refresh_token',
      refresh_token: REFRESH_TOKEN,
      client_id: CLIENT_ID,
    }),
  });

  if (!res.ok) throw new Error(`token_refresh_${res.status}`);

  const data = await res.json();
  if (!data.access_token) throw new Error('token_refresh_no_access_token');

  cachedAccessToken = data.access_token;
  tokenExpiresAt    = data.expires_in
    ? Date.now() + data.expires_in * 1000
    : Date.now() + 3600_000;

  return cachedAccessToken;
}

async function fetchUsage() {
  const token = await getAccessToken();
  const res = await fetch(USAGE_URL, {
    headers: {
      Authorization: `Bearer ${token}`,
      'anthropic-beta': OAUTH_BETA,
      'User-Agent': USER_AGENT,
    },
  });

  if (!res.ok) throw new Error(`usage_api_${res.status}`);
  return res.json();
}

function buildFrames(usage) {
  const frames = [];

  const sessionPct = Math.round(usage.five_hour?.utilization ?? 0);
  frames.push({ icon: ICON_SESSION, goalData: { start: 0, current: sessionPct, end: 100, unit: '%' } });
  frames.push({ icon: ICON_SESSION, text: `5h ${sessionPct}%` });

  const weekPct = Math.round(usage.seven_day?.utilization ?? 0);
  frames.push({ icon: ICON_WEEKLY, goalData: { start: 0, current: weekPct, end: 100, unit: '%' } });
  frames.push({ icon: ICON_WEEKLY, text: `7d ${weekPct}%` });

  const extra = usage.extra_usage;
  if (extra?.is_enabled) {
    const used  = Number(extra.used_credits  ?? 0).toFixed(2);
    const limit = Number(extra.monthly_limit ?? 0).toFixed(0);
    frames.push({ icon: ICON_CREDITS, text: `$${used}/$${limit}` });
  }

  return { frames };
}

const server = http.createServer(async (req, res) => {
  if (req.url !== '/api' && req.url !== '/api/') {
    res.writeHead(404);
    res.end();
    return;
  }

  res.setHeader('Content-Type', 'application/json');

  try {
    const usage = await fetchUsage();
    res.writeHead(200);
    res.end(JSON.stringify(buildFrames(usage)));
  } catch (err) {
    const type  = err.message.split(':')[0];
    const isAuth = type.includes('401') || type.includes('403');
    console.error('[claude-lametric] error:', type);
    res.writeHead(200);
    res.end(JSON.stringify({
      frames: [{ text: isAuth ? 'Bad token' : 'API error', icon: ICON_ERROR }],
    }));
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[claude-lametric] listening on port ${PORT}`);
});
