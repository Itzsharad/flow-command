// Flow Command usage server (Cloudflare Worker + D1).
// - Counts AI tasks per computer, gives a 14-day Pro trial, then 15 free AI tasks a week.
// - Checks Lemon Squeezy license keys for Pro.
// - Forwards AI calls to Gemini with the server's key, so the key never ships inside the app.
// Nothing the user says or sees is stored — only counts.

const GEMINI = 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';
const LS = 'https://api.lemonsqueezy.com/v1/licenses';
const CALLS_PER_TASK = 45;     // one task = up to this many AI steps
const PRO_DAILY_TASKS = 60;    // fair use: no normal person reaches this
const TRIAL_TASKS = 30;        // the trial ends after 7 days or 30 AI tasks, whichever comes first
const LICENSE_RECHECK = 6 * 3600;

const json = (obj, status = 200, headers = {}) =>
  new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json', ...headers } });
const fail = (status, code, message, headers = {}) => json({ error: { code, message } }, status, headers);
const now = () => Math.floor(Date.now() / 1000);

export function weekOf(ts) {
  const d = new Date(ts * 1000);
  const day = (d.getUTCDay() + 6) % 7;               // Monday = 0
  const monday = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - day));
  return monday.toISOString().slice(0, 10);
}
export function nextWeek(ts) {
  const m = new Date(weekOf(ts) + 'T00:00:00Z');
  return Math.floor(m.getTime() / 1000) + 7 * 86400;
}
const dayOf = (ts) => new Date(ts * 1000).toISOString().slice(0, 10);
const validDevice = (d) => typeof d === 'string' && /^[a-f0-9]{64}$/.test(d);
const validTask = (t) => typeof t === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(t);

async function device(env, id) {
  let row = await env.DB.prepare('SELECT id, first_seen, license FROM devices WHERE id = ?').bind(id).first();
  if (!row) {
    row = { id, first_seen: now(), license: null };
    await env.DB.prepare('INSERT OR IGNORE INTO devices (id, first_seen) VALUES (?, ?)').bind(id, row.first_seen).run();
  }
  return row;
}

async function lsCall(path, params) {
  const r = await fetch(`${LS}/${path}`, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params).toString(),
  });
  return r.json().catch(() => ({}));
}

function storeOK(env, data) {
  if (!env.LS_STORE_ID) return true;
  return String(data?.meta?.store_id ?? '') === String(env.LS_STORE_ID);
}

async function licenseActive(env, key, dev) {
  if (!key) return false;
  const act = await env.DB.prepare('SELECT instance_id FROM activations WHERE key = ? AND device = ?').bind(key, dev).first();
  if (!act) return false;                                   // must be activated on this computer
  const cached = await env.DB.prepare('SELECT status, checked_at FROM licenses WHERE key = ?').bind(key).first();
  if (cached && now() - cached.checked_at < LICENSE_RECHECK) return cached.status === 'active';
  let status = cached?.status || 'unknown';
  try {
    const data = await lsCall('validate', { license_key: key, instance_id: act.instance_id });
    if (data && typeof data.valid === 'boolean') {
      status = data.valid && storeOK(env, data) && data.license_key?.status === 'active' ? 'active' : (data.license_key?.status || 'invalid');
    }
  } catch (e) { /* Lemon Squeezy unreachable: keep the last known status */ }
  await env.DB.prepare('INSERT INTO licenses (key, status, checked_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET status = excluded.status, checked_at = excluded.checked_at')
    .bind(key, status, now()).run();
  return status === 'active';
}

async function account(env, devId) {
  const dev = await device(env, devId);
  const t = now();
  const trialEnds = dev.first_seen + Number(env.TRIAL_DAYS || 7) * 86400;
  let plan = 'free', trialLeft = null;
  if (await licenseActive(env, dev.license, devId)) plan = 'pro';
  else if (t < trialEnds) {
    const total = (await env.DB.prepare('SELECT COUNT(*) AS n FROM tasks WHERE device = ?').bind(devId).first()).n;
    trialLeft = Math.max(0, Number(env.TRIAL_TASKS || TRIAL_TASKS) - total);
    if (trialLeft > 0) plan = 'trial';
  }
  const week = weekOf(t);
  const used = (await env.DB.prepare('SELECT COUNT(*) AS n FROM tasks WHERE device = ? AND week = ?').bind(devId, week).first()).n;
  const limit = plan === 'free' ? Number(env.FREE_WEEKLY || 15) : null;
  return { plan, used, limit, resetsAt: nextWeek(t), trialEndsAt: plan === 'pro' ? null : trialEnds, trialLeft: plan === 'trial' ? trialLeft : null, week };
}

function accountHeaders(a) {
  return {
    'x-fc-plan': a.plan, 'x-fc-used': String(a.used), 'x-fc-limit': a.limit == null ? '' : String(a.limit),
    'x-fc-resets': String(a.resetsAt), 'x-fc-trial-ends': a.trialEndsAt == null ? '' : String(a.trialEndsAt),
    'x-fc-trial-left': a.trialLeft == null ? '' : String(a.trialLeft),
  };
}
const publicAccount = (a) => ({ plan: a.plan, used: a.used, limit: a.limit, resetsAt: a.resetsAt, trialEndsAt: a.trialEndsAt, trialLeft: a.trialLeft });

async function handleAI(req, env) {
  const devId = req.headers.get('x-fc-device'), task = req.headers.get('x-fc-task');
  if (!validDevice(devId) || !validTask(task)) return fail(400, 'bad_request', 'Missing device or task.');
  let body;
  try { body = await req.json(); } catch (e) { return fail(400, 'bad_request', 'Bad request.'); }
  const a = await account(env, devId);
  const existing = await env.DB.prepare('SELECT calls FROM tasks WHERE device = ? AND week = ? AND task_id = ?').bind(devId, a.week, task).first();
  if (!existing) {
    if (a.limit != null && a.used >= a.limit) {
      return fail(402, 'limit', `You've used this week's ${a.limit} free AI tasks. Instant commands still work. Upgrade to Pro for unlimited, or wait until Monday.`, accountHeaders(a));
    }
    if (a.plan !== 'free') {
      const today = (await env.DB.prepare('SELECT COUNT(*) AS n FROM tasks WHERE device = ? AND day = ?').bind(devId, dayOf(now())).first()).n;
      if (today >= PRO_DAILY_TASKS) return fail(429, 'fair_use', "You've hit today's fair-use limit. It resets tomorrow.", accountHeaders(a));
    }
  } else if (existing.calls >= CALLS_PER_TASK) {
    return fail(429, 'too_many_steps', 'This task took too many steps, so I stopped it. Try saying it in smaller parts.', accountHeaders(a));
  }

  // Daily spending cap: when the day's AI use passes DAILY_CALL_CAP, only paying users are served.
  const cap = Number(env.DAILY_CALL_CAP || 0);
  if (cap > 0 && a.plan !== 'pro') {
    const row = await env.DB.prepare('SELECT calls FROM daily WHERE day = ?').bind(dayOf(now())).first();
    if (row && row.calls >= cap) {
      return fail(503, 'busy', "Flow Command's AI is very busy today. Instant commands still work; AI tasks will be back soon. Pro members always get through.", accountHeaders(a));
    }
  }

  // Only the fields the app uses are forwarded; the model is chosen here, not by the app.
  const out = { model: env.MODEL || 'gemini-3.8-flash', messages: body.messages };
  if (typeof body.temperature === 'number') out.temperature = body.temperature;
  if (typeof body.max_tokens === 'number') out.max_tokens = Math.min(body.max_tokens, 2000);
  if (!Array.isArray(out.messages) || out.messages.length > 20) return fail(400, 'bad_request', 'Bad request.');

  const upstream = await fetch(env.UPSTREAM || GEMINI, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${env.GEMINI_KEY}` },
    body: JSON.stringify(out),
  });
  const text = await upstream.text();
  if (upstream.ok) {
    await env.DB.prepare('INSERT INTO tasks (device, week, day, task_id, calls) VALUES (?, ?, ?, ?, 1) ON CONFLICT(device, week, task_id) DO UPDATE SET calls = calls + 1')
      .bind(devId, a.week, dayOf(now()), task).run();
    await env.DB.prepare('INSERT INTO daily (day, calls) VALUES (?, 1) ON CONFLICT(day) DO UPDATE SET calls = calls + 1').bind(dayOf(now())).run();
    if (!existing) { a.used += 1; if (a.trialLeft != null) a.trialLeft = Math.max(0, a.trialLeft - 1); }
  }
  const status = upstream.ok ? 200 : (upstream.status === 429 ? 503 : 502);
  if (!upstream.ok) return fail(status, 'ai_busy', upstream.status === 429 ? 'The AI is busy right now. Try again in a minute.' : 'The AI had a problem. Try again.', accountHeaders(a));
  return new Response(text, { status, headers: { 'content-type': 'application/json', ...accountHeaders(a) } });
}

async function handleLicense(req, env) {
  let b;
  try { b = await req.json(); } catch (e) { return fail(400, 'bad_request', 'Bad request.'); }
  const devId = b.device, key = String(b.license || '').trim();
  if (!validDevice(devId) || key.length < 8 || key.length > 100) return fail(400, 'bad_request', 'That doesn\'t look like a license key.');
  await device(env, devId);
  if (b.remove) {
    const act = await env.DB.prepare('SELECT instance_id FROM activations WHERE key = ? AND device = ?').bind(key, devId).first();
    if (act) { try { await lsCall('deactivate', { license_key: key, instance_id: act.instance_id }); } catch (e) {} }
    await env.DB.prepare('DELETE FROM activations WHERE key = ? AND device = ?').bind(key, devId).run();
    await env.DB.prepare('UPDATE devices SET license = NULL WHERE id = ? AND license = ?').bind(devId, key).run();
    return json(publicAccount(await account(env, devId)));
  }
  const already = await env.DB.prepare('SELECT instance_id FROM activations WHERE key = ? AND device = ?').bind(key, devId).first();
  if (!already) {
    let data;
    try { data = await lsCall('activate', { license_key: key, instance_name: String(b.name || 'Computer').slice(0, 60) }); }
    catch (e) { return fail(503, 'license', "Couldn't reach the license server. Check your internet and try again."); }
    if (!data.activated || !data.instance?.id) {
      const msg = /limit/i.test(data.error || '') ? 'This license is already used on 2 computers. Remove it from one first.' : (data.error || 'That license key didn\'t work.');
      return fail(400, 'license', msg);
    }
    if (!storeOK(env, data)) return fail(400, 'license', 'That license key is for a different product.');
    await env.DB.prepare('INSERT OR REPLACE INTO activations (key, device, instance_id) VALUES (?, ?, ?)').bind(key, devId, data.instance.id).run();
    await env.DB.prepare('INSERT INTO licenses (key, status, checked_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET status = excluded.status, checked_at = excluded.checked_at')
      .bind(key, data.license_key?.status === 'active' ? 'active' : (data.license_key?.status || 'active'), now()).run();
  }
  await env.DB.prepare('UPDATE devices SET license = ? WHERE id = ?').bind(key, devId).run();
  return json(publicAccount(await account(env, devId)));
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      if (req.method === 'GET' && url.pathname === '/') return new Response('Flow Command API is running.');
      if (req.method !== 'POST') return fail(405, 'method', 'Use POST.');
      if (url.pathname === '/v1/status') {
        const b = await req.json().catch(() => ({}));
        if (!validDevice(b.device)) return fail(400, 'bad_request', 'Missing device.');
        return json(publicAccount(await account(env, b.device)));
      }
      if (url.pathname === '/v1/ai') return await handleAI(req, env);
      if (url.pathname === '/v1/license') return await handleLicense(req, env);
      return fail(404, 'not_found', 'Not found.');
    } catch (e) {
      return fail(500, 'server', 'Server error. Try again.');
    }
  },
};
