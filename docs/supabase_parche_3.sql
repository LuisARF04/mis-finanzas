-- =====================================================================
--  Parche 3 · Notificaciones generales (tasa diaria y nueva versión)
--
--  Pégalo en el SQL Editor y dale Run. No borra nada; se puede correr
--  varias veces.
--
--  Diferencia con las tablas de antes: store_links guarda "este teléfono
--  puede ver ESTA tienda"; app_devices es más simple, es solo
--  "este teléfono existe y quiere las notificaciones generales de la app"
--  (la tasa del dólar, avisos de nueva versión). No tiene nada que ver
--  con ninguna tienda.
-- =====================================================================

create table if not exists public.app_devices (
  token_hash    text primary key,              -- huella del identificador del teléfono (nunca el identificador en sí)
  fcm_token     text,
  notify_rate   boolean not null default true,  -- tasa del dólar, todos los días
  notify_update boolean not null default true,  -- cuando sale una versión nueva de la app
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.app_devices enable row level security;
revoke all on public.app_devices from anon, authenticated;
-- (nadie de afuera lee ni escribe esta tabla directo; solo las funciones de abajo,
--  que corren con permisos propios, y la función del servidor que manda los avisos)

-- Wallet llama a esto para decir "aquí estoy, mándame las notificaciones generales"
create or replace function public.wallet_register_device(
  p_token     text,
  p_fcm_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash text;
begin
  if p_token is null or length(p_token) < 32 then raise exception 'invalid_token'; end if;
  v_hash := public._wallet_hash(p_token);

  insert into public.app_devices (token_hash, fcm_token)
  values (v_hash, p_fcm_token)
  on conflict (token_hash) do update
    set fcm_token = excluded.fcm_token,
        updated_at = now();

  return jsonb_build_object('status', 'ok');
end;
$$;

revoke all on function public.wallet_register_device(text, text) from public;
grant execute on function public.wallet_register_device(text, text) to anon, authenticated;
