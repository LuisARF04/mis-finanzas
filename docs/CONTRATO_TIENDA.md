# Wallet ⇄ App de tienda — Contrato

Este documento explica **qué debe hacer la app de tienda** para que la Cuenta Empresarial de Wallet funcione.
Todo pasa por **Supabase** (el esquema está en `supabase_wallet.sql`).

## Cómo funciona, en 5 pasos

1. En **Wallet**: `+` → *Agregar Cuenta Empresarial* → se escribe el **ID de 8 dígitos** de la tienda.
2. Wallet verifica que ese ID existe. Si no existe, avisa. Si existe, **se queda esperando** y muestra un **código de 4 dígitos**.
3. En la **app de tienda** aparece la solicitud con el mismo código. El dueño la **aprueba** (o la rechaza).
4. Wallet se entera sola (pregunta cada 3 segundos y al volver a abrirse) y abre la pantalla de la tienda.
5. Desde ese momento Wallet ve el resumen (hoy / este mes) y la lista de ventas. Si el dueño **revoca** el acceso, Wallet lo avisa.

> El ID por sí solo **no da acceso a nada**: sin la aprobación de la app de tienda, Wallet no puede ver ninguna venta.

## Lo que necesita la app de tienda

### 1. Una tienda con ID de 8 dígitos
Tabla `stores`: `id` (8 dígitos, único), `name`, `currency` (por defecto `CUP`) y `owner_id` (el usuario dueño, con Supabase Auth).

```js
await supabase.from('stores').insert({ id: '12345678', name: 'Bodega La Esquina', owner_id: user.id });
```

### 2. Registrar cada venta
Tabla `sales`: `store_id`, `total`, `payment_method` (opcional), `items` (lista), `note` (opcional) y `external_id` (el id que ya tiene esa venta en la app de tienda). La fecha se pone sola.

```js
await supabase.from('sales').upsert({
  store_id: '12345678',
  external_id: String(venta.id),          // evita duplicados si se vuelve a enviar
  total: 3070,
  payment_method: 'Efectivo',
  items: [{ name: 'Leche en polvo', qty: 2, price: 1400 }, { name: 'Galletas', qty: 3, price: 90 }]
}, { onConflict: 'store_id,external_id' });
```
`items` es una lista de `{ name, qty, price }` (`price` = precio de **una** unidad). Wallet los muestra como "2× Leche en polvo, 3× Galletas".

### 3. Subir el historial anterior (una sola vez)
**Wallet muestra todas las ventas que existan en la tabla `sales`, sin importar la fecha: no corta nada por la fecha de vinculación.**
Si la app de tienda ya tenía ventas guardadas antes de conectarse a Supabase, esas ventas **solo existen en el teléfono de la tienda** hasta que se suban. Hay que subirlas **con su fecha original** (`created_at`), no con la de hoy:

```js
const filas = ventasLocales.map(v => ({
  store_id: '12345678',
  external_id: String(v.id),                       // el id que ya tiene cada venta
  created_at: new Date(v.fecha).toISOString(),     // la fecha ORIGINAL de la venta
  total: v.total,
  payment_method: v.metodoPago,
  items: v.items.map(i => ({ name: i.nombre, qty: i.cantidad, price: i.precio }))
}));
for (let i = 0; i < filas.length; i += 500)
  await supabase.from('sales').upsert(filas.slice(i, i + 500), { onConflict: 'store_id,external_id' });
```
Se puede ejecutar varias veces sin duplicar ventas (gracias a `external_id`). Antes hay que ejecutar `supabase_parche_1.sql` si el SQL principal se ejecutó antes de agregar esa columna.

**Cómo comprobar qué hay en la nube** (SQL Editor):
```sql
select count(*) as ventas, min(created_at) as la_mas_antigua, max(created_at) as la_mas_nueva
from public.sales where store_id = '12345678';
```
Wallet muestra lo mismo debajo de las tarjetas: "N ventas registradas · la más antigua, del …".

### 4. Mostrar las solicitudes pendientes y decidir
Una solicitud es válida durante **15 minutos**. Hay que mostrar el **código** para que el dueño compruebe que coincide con el de Wallet.

```js
const desde = new Date(Date.now() - 15 * 60 * 1000).toISOString();
const { data } = await supabase.from('store_links')
  .select('id, code, device_label, created_at')
  .eq('store_id', '12345678').eq('status', 'pending').gt('created_at', desde);

// Aprobar, rechazar o (más tarde) revocar el acceso de un teléfono:
await supabase.from('store_links')
  .update({ status: 'approved' /* o 'rejected' / 'revoked' */, decided_at: new Date().toISOString() })
  .eq('id', linkId);
```
Conviene mostrar también la lista de teléfonos ya aprobados (`status = 'approved'`) con un botón **Revocar**.

## Reglas de seguridad (ya incluidas en el SQL)

- Wallet **no puede leer ni escribir las tablas**; solo usa funciones `wallet_*`.
- Cada teléfono tiene un identificador secreto; el servidor guarda solo su **huella**, nunca el identificador.
- Máximo **5 solicitudes pendientes por hora** en cada tienda (evita que alguien que adivine el ID inunde al dueño).
- El dueño solo puede cambiar `status` y `decided_at` de una vinculación, nada más.
- Los totales "Hoy / Este mes" se calculan con **hora de Cuba** (`America/Havana`).

## Conectar Wallet (cuando Supabase esté listo)

En `www/index.html`, cerca del final, hay dos líneas vacías:

```js
const BIZ_URL = '';   // ej.: 'https://abcdefgh.supabase.co'
const BIZ_KEY = '';   // la clave pública ("anon" o "publishable") — NUNCA la "service_role"
```
Mientras estén vacías, Wallet funciona en **modo demostración** (usa el ID `12345678`).

## Prueba rápida sin la app de tienda
1. Ejecuta `supabase_wallet.sql`.
2. Inserta una tienda y ventas con el ejemplo del final del SQL.
3. En Wallet pide acceso con ese ID; copia el código que muestra.
4. En el SQL Editor aprueba la solicitud (consulta de ejemplo al final del SQL). Wallet se vincula sola.
