-- =====================================================================
--  Parche 1 · Historial de ventas
--
--  Para quien YA ejecutó supabase_wallet.sql. Pégalo en SQL Editor y dale Run.
--  No borra nada. Se puede ejecutar más de una vez.
--
--  Qué hace:
--    1) Agrega a cada venta un identificador propio (external_id) para poder
--       subir el historial de la app de tienda SIN duplicar ventas.
--    2) Amplía el resumen para que Wallet muestre cuántas ventas hay en total
--       y desde cuándo (así se ve enseguida si falta historial por subir).
-- =====================================================================

alter table public.sales add column if not exists external_id text;
create unique index if not exists sales_store_external_uidx on public.sales (store_id, external_id);

create or replace function public.wallet_sales_summary(p_store_id text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today timestamptz;
  v_month timestamptz;
begin
  if not public._wallet_authorized(p_store_id, p_token) then
    raise exception 'not_authorized';
  end if;

  v_today := date_trunc('day',   now() at time zone 'America/Havana') at time zone 'America/Havana';
  v_month := date_trunc('month', now() at time zone 'America/Havana') at time zone 'America/Havana';

  return (
    select jsonb_build_object(
             'today_total',  coalesce(sum(s.total) filter (where s.created_at >= v_today), 0),
             'today_count',  count(*) filter (where s.created_at >= v_today),
             'month_total',  coalesce(sum(s.total) filter (where s.created_at >= v_month), 0),
             'month_count',  count(*) filter (where s.created_at >= v_month),
             'total_count',  count(*),
             'first_sale_at', min(s.created_at)
           )
      from public.sales s
     where s.store_id = p_store_id
  );
end;
$$;

-- Los permisos de la función no cambian (se conservan los que ya tenía).
