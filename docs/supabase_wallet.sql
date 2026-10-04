-- =====================================================================
--  Wallet <-> App de tienda  ·  Esquema para Supabase
--
--  Cómo usarlo:
--    Supabase -> SQL Editor -> New query -> pega TODO este archivo -> Run.
--  Se puede ejecutar más de una vez sin problema.
--
--  Idea de seguridad:
--    * Wallet NO puede leer ni escribir las tablas directamente.
--    * Wallet solo usa las funciones wallet_* de más abajo.
--    * Para ver las ventas de una tienda, Wallet necesita que la APP DE
--      TIENDA haya aprobado la vinculación de ese teléfono (store_links).
--    * Wallet guarda un identificador secreto del teléfono; el servidor
--      solo guarda su huella (hash), nunca el identificador en sí.
-- =====================================================================


-- ---------- 1) Tablas ------------------------------------------------

create table if not exists public.stores (
  id          text primary key check (id ~ '^[0-9]{8}$'),     -- ID de 8 dígitos de la tienda
  name        text not null,
  currency    text not null default 'CUP',
  owner_id    uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.sales (
  id              uuid primary key default gen_random_uuid(),
  store_id        text not null references public.stores (id) on delete cascade,
  created_at      timestamptz not null default now(),
  total           numeric(14,2) not null check (total >= 0),
  payment_method  text,                                        -- 'Efectivo', 'Transfermóvil', 'EnZona'...
  items           jsonb not null default '[]'::jsonb,          -- [{"name":"Pan","qty":2,"price":25}]
  note            text,
  external_id     text                                         -- id de la venta en la app de tienda (para subir el historial sin duplicar)
);
-- (por si la tabla ya existía de antes, sin esta columna)
alter table public.sales add column if not exists external_id text;
create index if not exists sales_store_created_idx on public.sales (store_id, created_at desc);
create unique index if not exists sales_store_external_uidx on public.sales (store_id, external_id);

create table if not exists public.store_links (
  id            uuid primary key default gen_random_uuid(),
  store_id      text not null references public.stores (id) on delete cascade,
  token_hash    text not null,                                 -- huella del identificador del teléfono
  code          text not null check (code ~ '^[0-9]{4}$'),     -- código de verificación que se ve en ambas apps
  device_label  text,
  status        text not null default 'pending'
                check (status in ('pending', 'approved', 'rejected', 'revoked')),
  created_at    timestamptz not null default now(),            -- fecha de la solicitud (caduca a los 15 min)
  decided_at    timestamptz,
  last_seen     timestamptz,
  unique (store_id, token_hash)
);
create index if not exists store_links_store_status_idx on public.store_links (store_id, status);


-- ---------- 2) Seguridad de las tablas -------------------------------

alter table public.stores      enable row level security;
alter table public.sales       enable row level security;
alter table public.store_links enable row level security;

-- El rol anónimo (Wallet) no tiene ningún acceso directo a las tablas.
revoke all on public.stores      from anon;
revoke all on public.sales       from anon;
revoke all on public.store_links from anon;

-- La app de tienda (usuario con sesión) solo ve y maneja lo de SU tienda.
drop policy if exists stores_owner_all on public.stores;
create policy stores_owner_all on public.stores
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

drop policy if exists sales_owner_all on public.sales;
create policy sales_owner_all on public.sales
  for all to authenticated
  using (exists (select 1 from public.stores s where s.id = sales.store_id and s.owner_id = auth.uid()))
  with check (exists (select 1 from public.stores s where s.id = sales.store_id and s.owner_id = auth.uid()));

drop policy if exists links_owner_select on public.store_links;
create policy links_owner_select on public.store_links
  for select to authenticated
  using (exists (select 1 from public.stores s where s.id = store_links.store_id and s.owner_id = auth.uid()));

drop policy if exists links_owner_update on public.store_links;
create policy links_owner_update on public.store_links
  for update to authenticated
  using (exists (select 1 from public.stores s where s.id = store_links.store_id and s.owner_id = auth.uid()))
  with check (exists (select 1 from public.stores s where s.id = store_links.store_id and s.owner_id = auth.uid()));

-- El dueño solo puede cambiar el estado de una vinculación (aprobar / rechazar / revocar).
revoke all on public.store_links from authenticated;
grant select on public.store_links to authenticated;
grant update (status, decided_at) on public.store_links to authenticated;


-- ---------- 3) Funciones internas (nadie de afuera puede llamarlas) --

create or replace function public._wallet_hash(p_token text)
returns text
language sql
immutable
as $$
  select encode(sha256(convert_to(p_token, 'utf8')), 'hex')
$$;

create or replace function public._wallet_authorized(p_store_id text, p_token text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.store_links l
     where l.store_id   = p_store_id
       and l.token_hash = public._wallet_hash(p_token)
       and l.status     = 'approved'
  )
$$;

revoke all on function public._wallet_hash(text) from public, anon, authenticated;
revoke all on function public._wallet_authorized(text, text) from public, anon, authenticated;


-- ---------- 4) Funciones que usa Wallet ------------------------------

-- 4.1  Pedir acceso a una tienda con su ID de 8 dígitos
create or replace function public.wallet_request_link(
  p_store_id text,
  p_token    text,
  p_code     text,
  p_label    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_store  public.stores%rowtype;
  v_link   public.store_links%rowtype;
  v_hash   text;
  v_exists boolean;
begin
  if p_store_id is null or p_store_id !~ '^[0-9]{8}$' then raise exception 'invalid_store_id'; end if;
  if p_token is null or length(p_token) < 32          then raise exception 'invalid_token';    end if;
  if p_code is null or p_code !~ '^[0-9]{4}$'         then raise exception 'invalid_code';     end if;

  select * into v_store from public.stores where id = p_store_id;
  if not found then raise exception 'store_not_found'; end if;

  v_hash := public._wallet_hash(p_token);
  select * into v_link from public.store_links
   where store_id = p_store_id and token_hash = v_hash;
  v_exists := found;

  -- Ya estaba vinculado
  if v_exists and v_link.status = 'approved' then
    return jsonb_build_object('status', 'approved', 'store_name', v_store.name, 'currency', v_store.currency);
  end if;

  -- Misma solicitud pendiente: se renueva el código y el plazo
  if v_exists and v_link.status = 'pending' then
    update public.store_links set code = p_code, created_at = now() where id = v_link.id;
    return jsonb_build_object('status', 'pending');
  end if;

  -- Solicitud nueva (o volver a pedir tras un rechazo): máximo 5 pendientes por hora en cada tienda
  if (select count(*) from public.store_links
       where store_id = p_store_id and status = 'pending' and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'too_many_requests';
  end if;

  if v_exists then
    update public.store_links
       set status = 'pending', code = p_code, device_label = left(p_label, 60),
           created_at = now(), decided_at = null
     where id = v_link.id;
  else
    insert into public.store_links (store_id, token_hash, code, device_label)
    values (p_store_id, v_hash, p_code, left(p_label, 60));
  end if;

  return jsonb_build_object('status', 'pending');
end;
$$;

-- 4.2  Preguntar si la tienda ya confirmó
create or replace function public.wallet_link_status(p_store_id text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link  public.store_links%rowtype;
  v_store public.stores%rowtype;
begin
  select * into v_link from public.store_links
   where store_id = p_store_id and token_hash = public._wallet_hash(p_token);
  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  if v_link.status = 'pending' and v_link.created_at < now() - interval '15 minutes' then
    return jsonb_build_object('status', 'expired');
  end if;

  update public.store_links set last_seen = now() where id = v_link.id;

  if v_link.status = 'approved' then
    select * into v_store from public.stores where id = p_store_id;
    return jsonb_build_object('status', 'approved', 'store_name', v_store.name, 'currency', v_store.currency);
  end if;

  return jsonb_build_object('status', v_link.status);
end;
$$;

-- 4.3  Lista de ventas (más nuevas primero; p_before sirve para pedir la página siguiente)
create or replace function public.wallet_get_sales(
  p_store_id text,
  p_token    text,
  p_before   timestamptz default null,
  p_limit    integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._wallet_authorized(p_store_id, p_token) then
    raise exception 'not_authorized';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select s.id, s.created_at, s.total, s.payment_method, s.items, s.note
          from public.sales s
         where s.store_id = p_store_id
           and (p_before is null or s.created_at < p_before)
         order by s.created_at desc
         limit least(greatest(coalesce(p_limit, 50), 1), 100)
      ) x
  ), '[]'::jsonb);
end;
$$;

-- 4.4  Resumen: lo vendido hoy y este mes (hora de Cuba)
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

-- 4.5  Quitar la vinculación (cuando se quita la tienda en Wallet o se cancela una solicitud)
create or replace function public.wallet_unlink(p_store_id text, p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.store_links
   where store_id = p_store_id and token_hash = public._wallet_hash(p_token);
  return jsonb_build_object('status', 'none');
end;
$$;


-- ---------- 5) Permisos de las funciones de Wallet -------------------

revoke all on function public.wallet_request_link(text, text, text, text)        from public;
revoke all on function public.wallet_link_status(text, text)                      from public;
revoke all on function public.wallet_get_sales(text, text, timestamptz, integer)  from public;
revoke all on function public.wallet_sales_summary(text, text)                    from public;
revoke all on function public.wallet_unlink(text, text)                           from public;

grant execute on function public.wallet_request_link(text, text, text, text)        to anon, authenticated;
grant execute on function public.wallet_link_status(text, text)                      to anon, authenticated;
grant execute on function public.wallet_get_sales(text, text, timestamptz, integer)  to anon, authenticated;
grant execute on function public.wallet_sales_summary(text, text)                    to anon, authenticated;
grant execute on function public.wallet_unlink(text, text)                           to anon, authenticated;


-- ---------- 6) Para probar sin la app de tienda (opcional) -----------
-- Reemplaza el UUID por el de tu usuario (Authentication -> Users):
--
--   insert into public.stores (id, name, owner_id)
--   values ('12345678', 'Mi Tienda', '00000000-0000-0000-0000-000000000000');
--
--   insert into public.sales (store_id, total, payment_method, items)
--   values ('12345678', 3070, 'Efectivo',
--           '[{"name":"Leche en polvo","qty":2,"price":1400},{"name":"Galletas","qty":3,"price":90}]');
--
-- Aprobar a mano la solicitud de un teléfono (el código sale en Wallet):
--
--   update public.store_links
--      set status = 'approved', decided_at = now()
--    where store_id = '12345678' and status = 'pending' and code = '1234';
