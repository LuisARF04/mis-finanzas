// =====================================================================
//  notify-sale · Edge Function de Supabase
//
//  Se dispara sola cada vez que se guarda una venta nueva (conectada
//  por un Database Webhook: tabla "sales", evento INSERT).
//  Busca los teléfonos vinculados y aprobados de esa tienda, y a cada
//  uno le manda una notificación push con el monto y los productos.
//
//  Cómo instalarla: Supabase → Edge Functions → Deploy a new function
//  → Via Editor → nómbrala "notify-sale" → pega TODO este archivo →
//  Deploy function. Luego, en "Manage secrets", agrega:
//    FCM_PROJECT_ID          -> el "Project ID" de Firebase
//    FCM_SERVICE_ACCOUNT_JSON -> el contenido completo del archivo de
//                                 la cuenta de servicio que descargaste
//                                 en Firebase (Configuración del
//                                 proyecto → Cuentas de servicio →
//                                 Generar nueva clave privada)
// =====================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { GoogleAuth } from 'npm:google-auth-library@9';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const FCM_PROJECT_ID = Deno.env.get('FCM_PROJECT_ID') ?? '';
const SERVICE_ACCOUNT_JSON = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON') ?? '';

// Hasta 4 productos en el texto de la notificación; si hay más, se resume
function describeItems(items: unknown): string {
  if (!Array.isArray(items) || items.length === 0) return 'Venta';
  const names = items.map((i: any) => (i && i.qty > 1 ? `${i.qty}× ${i.name}` : (i && i.name) || '')).filter(Boolean);
  if (names.length <= 4) return names.join(', ');
  return names.slice(0, 4).join(', ') + ` y ${names.length - 4} más`;
}

function money(n: number, cur: string): string {
  const v = (Number(n) || 0).toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `${v} ${cur}`;
}

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
      message: {
        token: fcmToken,
        notification: { title, body },
        android: { priority: 'high', notification: { sound: 'default' } },
      },
    }),
  });
  if (!r.ok) {
    const detail = await r.text();
    return { ok: false, status: r.status, detail };
  }
  return { ok: true };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method_not_allowed', { status: 405 });
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

  const sale = payload?.record;
  if (!sale || !sale.store_id) return new Response('ignored', { status: 200 });

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: store } = await supabase.from('stores').select('name, currency').eq('id', sale.store_id).maybeSingle();
  const { data: links, error } = await supabase
    .from('store_links')
    .select('fcm_token')
    .eq('store_id', sale.store_id)
    .eq('status', 'approved')
    .not('fcm_token', 'is', null);

  if (error) {
    console.error('Error buscando dispositivos vinculados:', error.message);
    return new Response('db_error', { status: 500 });
  }
  if (!links || links.length === 0) return new Response('no_devices', { status: 200 });

  const title = `${store?.name || 'Tu tienda'} · nueva venta`;
  const body = `${money(sale.total, store?.currency || 'CUP')} · ${describeItems(sale.items)}`;

  const results = await Promise.all(
    links.map(async (l) => {
      const r = await sendPush(l.fcm_token as string, title, body);
      // Un token "unregistered" o "invalid-argument" significa que esa app ya
      // no tiene ese token (se desinstaló, cambió, etc.): se limpia solo.
      if (!r.ok && (r.status === 404 || /UNREGISTERED|invalid-argument/i.test(r.detail || ''))) {
        await supabase.from('store_links').update({ fcm_token: null }).eq('store_id', sale.store_id).eq('fcm_token', l.fcm_token as string);
      }
      return r;
    })
  );

  const sent = results.filter((r) => r.ok).length;
  return new Response(JSON.stringify({ sent, of: results.length }), { status: 200, headers: { 'Content-Type': 'application/json' } });
});
