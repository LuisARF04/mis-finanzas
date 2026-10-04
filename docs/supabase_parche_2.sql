-- =====================================================================
--  Parche 2 · Notificaciones de ventas (Firebase)
--
--  Pégalo en el SQL Editor y dale Run. No borra nada; se puede correr
--  varias veces. Necesita el Parche 1 ya ejecutado (o el SQL principal
--  actualizado), porque reutiliza las mismas funciones wallet_*.
-- =====================================================================

-- Cada dispositivo vinculado puede guardar su "dirección" de notificaciones
alter table public.store_links add column if not exists fcm_token text;

-- Wallet llama a esto para decirle al servidor "avísame a mí de esta tienda"
create or replace function public.wallet_register_push(
  p_store_id  text,
  p_token     text,
  p_fcm_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer;
begin
  update public.store_links
     set fcm_token = p_fcm_token
   where store_id = p_store_id
     and token_hash = public._wallet_hash(p_token)
     and status = 'approved';
  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    raise exception 'not_authorized';
  end if;

  return jsonb_build_object('status', 'ok');
end;
$$;

revoke all on function public.wallet_register_push(text, text, text) from public;
grant execute on function public.wallet_register_push(text, text, text) to anon, authenticated;
