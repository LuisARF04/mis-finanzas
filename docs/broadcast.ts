// =====================================================================
//  broadcast · Edge Function de Supabase
//
//  Le manda una notificación a TODOS los teléfonos registrados que
//  tengan activada esa categoría ("notify_rate" o "notify_update").
//
//  No la llama Wallet directamente (eso sería peligroso: cualquiera
//  podría mandar notificaciones a todo el mundo). Solo la llaman los
//  robots de GitHub, con una clave secreta compartida que solo tú
//  conoces (BROADCAST_SECRET).
//
//  Cómo instalarla: igual que notify-sale.ts — Edge Functions →
//  Deploy a new function → Via Editor → nómbrala "broadcast" → pega
//  este archivo → Deploy. Usa los MISMOS secretos FCM_PROJECT_ID y
//  FCM_SERVICE_ACCOUNT_JSON que ya guardaste para notify-sale, más uno
//  nuevo: BROADCAST_SECRET (invéntate una clave larga y guárdala
//  también como secreto de este repositorio en GitHub, con el MISMO
//  valor exacto).
// =====================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { GoogleAuth } from 'npm:google-auth-library@9';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const FCM_PROJECT_ID = Deno.env.get('FCM_PROJECT_ID') ?? '';
const SERVICE_ACCOUNT_JSON = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON') ?? '';
const BROADCAST_SECRET = Deno.env.get('BROADCAST_SECRET') ?? '';

let cachedAuth: GoogleAuth | null = null;
async function fcmAccessToken(): Promise<string> {
  if (!cachedAuth) {
    const credentials = JSON.parse(SERVICE_ACCOUNT_JSON);
    cachedAuth = new GoogleAuth({ credentials, scopes: ['https://www.googleapis.com/auth/firebase.messaging'] });
  }
  const client = await cachedAuth.getClient();
  const res = await client.getAccessToken();
  const token = typeof res === 'string' ? res : res?.token;
  if (!token) throw new Error('no_access_token');
  return token;
}

async function sendPush(fcmToken: string, title: string, body: string) {
  const accessToken = await fcmAccessToken();
  const r = await fetch(`https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      message: { token: fcmToken, notification: { title, body }, android: { priority: 'high', notification: { sound: 'default' } } },
    }),
  });
  if (!r.ok) return { ok: false, status: r.status, detail: await r.text() };
  return { ok: true };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method_not_allowed', { status: 405 });

  const auth = req.headers.get('authorization') || '';
  if (!BROADCAST_SECRET || auth !== `Bearer ${BROADCAST_SECRET}`) {
    return new Response('unauthorized', { status: 401 });
  }
  if (!FCM_PROJECT_ID || !SERVICE_ACCOUNT_JSON) {
    console.error('Faltan los secretos FCM_PROJECT_ID / FCM_SERVICE_ACCOUNT_JSON');
    return new Response('missing_secrets', { status: 500 });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('bad_request', { status: 400 });
  }

  const { title, body, filter } = payload || {};
  if (!title || !body || !['notify_rate', 'notify_update'].includes(filter)) {
    return new Response('bad_request', { status: 400 });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: devices, error } = await supabase
    .from('app_devices')
    .select('token_hash, fcm_token')
    .eq(filter, true)
    .not('fcm_token', 'is', null);

  if (error) {
    console.error('Error leyendo app_devices:', error.message);
    return new Response('db_error', { status: 500 });
  }
  if (!devices || devices.length === 0) {
    return new Response(JSON.stringify({ sent: 0, of: 0 }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  const results = await Promise.all(
    devices.map(async (d) => {
      const r = await sendPush(d.fcm_token as string, title, body);
      if (!r.ok && (r.status === 404 || /UNREGISTERED|invalid-argument/i.test(r.detail || ''))) {
        await supabase.from('app_devices').update({ fcm_token: null }).eq('token_hash', d.token_hash);
      }
      return r;
    })
  );

  const sent = results.filter((r) => r.ok).length;
  return new Response(JSON.stringify({ sent, of: results.length }), { status: 200, headers: { 'Content-Type': 'application/json' } });
});
