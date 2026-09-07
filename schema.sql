-- ============================================================
--  MOTIVOS DE NO COMPRA - PDB
--  Esquema adaptado al archivo "Clientes No Compradores Totales"
--  Ejecutar completo, una sola vez, en el SQL Editor de Supabase.
-- ============================================================

-- ------------------------------------------------------------
-- 1. TABLAS
-- ------------------------------------------------------------

create table if not exists vendedores (
    codigo      text primary key,     -- ALEJANDRA_CAMARA
    nombre      text not null,        -- ALEJANDRA CAMARA
    supervisor  text,                 -- Federico Suarez / Gabriel Garofalo
    token       text unique not null,
    activo      boolean not null default true,
    creado_en   timestamptz not null default now()
);

create table if not exists motivos (
    id              text primary key,
    etiqueta        text not null,
    orden           int  not null,
    requiere_texto  boolean not null default false,
    activo          boolean not null default true
);

-- Un renglon por cliente que no compro en el periodo.
-- La carga el script cargar_periodo.py. El vendedor nunca escribe aca.
create table if not exists clientes_periodo (
    id                bigserial primary key,
    periodo           text not null,          -- '2026-08'
    vendedor_codigo   text not null references vendedores(codigo) on delete cascade,
    cliente_codigo    text not null,
    cliente_nombre    text not null,
    direccion         text,
    subcanal          text,
    estado            text,                   -- En riesgo / Caido / Sin actividad 2026
    meses_sin_comprar int,
    ultimo_mes        text,
    motivo_anterior   text references motivos(id),
    unique (periodo, vendedor_codigo, cliente_codigo)
);

create index if not exists ix_clientes_periodo_lookup
    on clientes_periodo (periodo, vendedor_codigo);

create table if not exists respuestas (
    id              bigserial primary key,
    periodo         text not null,
    vendedor_codigo text not null references vendedores(codigo) on delete cascade,
    cliente_codigo  text not null,
    motivo_id       text not null references motivos(id),
    detalle         text,
    creado_en       timestamptz not null default now(),
    actualizado_en  timestamptz not null default now(),
    unique (periodo, vendedor_codigo, cliente_codigo)
);

create index if not exists ix_respuestas_periodo
    on respuestas (periodo, vendedor_codigo);

-- Clave para abrir el tablero de seguimiento. Cambiala por la que quieras.
create table if not exists config (
    clave  text primary key,
    valor  text not null
);
insert into config (clave, valor) values ('clave_seguimiento', 'pdb2026')
on conflict (clave) do nothing;

-- ------------------------------------------------------------
-- 2. MOTIVOS
-- ------------------------------------------------------------

insert into motivos (id, etiqueta, orden, requiere_texto) values
    ('SIN_PLATA',    'Sin dinero',                    1, false),
    ('TIENE_STOCK',  'Tiene stock',                   2, false),
    ('CERRADO',      'Cerrado o no atendió',          3, false),
    ('MAYORISTA',    'Compra a mayorista',            4, false),
    ('COMPETENCIA',  'Compra a la competencia',       5, false),
    ('PRECIO',       'No acepta precio',              6, false),
    ('DEUDA',        'Bloqueado por deuda',           7, false),
    ('TEMPORADA',    'Temporada baja',                8, false),
    ('BAJA',         'Local cerrado definitivo',      9, false),
    ('NO_VISITADO',  'No lo visité',                 10, false),
    ('OTRO',         'Otro motivo',                  11, true)
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 3. SEGURIDAD
-- ------------------------------------------------------------
-- RLS prendido sin politicas: la clave publica no puede leer ni
-- escribir nada directo. Todo pasa por las funciones de abajo.

alter table vendedores       enable row level security;
alter table motivos          enable row level security;
alter table clientes_periodo enable row level security;
alter table respuestas       enable row level security;
alter table config           enable row level security;

-- ------------------------------------------------------------
-- 4. FUNCION: cartera del vendedor
-- ------------------------------------------------------------

create or replace function app_cartera(p_token text)
returns json
language plpgsql security definer set search_path = public as $$
declare
    v vendedores%rowtype;
    p text;
    r json;
begin
    select * into v from vendedores where token = p_token and activo = true;
    if not found then return json_build_object('error','token_invalido'); end if;

    select max(periodo) into p from clientes_periodo where vendedor_codigo = v.codigo;

    if p is null then
        return json_build_object(
            'vendedor', json_build_object('codigo',v.codigo,'nombre',v.nombre),
            'periodo', null, 'motivos','[]'::json, 'clientes','[]'::json);
    end if;

    select json_build_object(
        'vendedor', json_build_object('codigo',v.codigo,'nombre',v.nombre),
        'periodo', p,
        'motivos', (
            select coalesce(json_agg(json_build_object(
                'id',m.id,'etiqueta',m.etiqueta,'requiere_texto',m.requiere_texto
            ) order by m.orden),'[]'::json)
            from motivos m where m.activo = true),
        'clientes', (
            select coalesce(json_agg(json_build_object(
                'cliente_codigo',   c.cliente_codigo,
                'cliente_nombre',   c.cliente_nombre,
                'direccion',        c.direccion,
                'subcanal',         c.subcanal,
                'estado',           coalesce(c.estado,'Sin estado'),
                'meses_sin_comprar',c.meses_sin_comprar,
                'motivo_anterior',  c.motivo_anterior,
                'motivo_id',        rp.motivo_id,
                'detalle',          rp.detalle
            ) order by
                case coalesce(c.estado,'')
                    when 'En riesgo' then 1
                    when 'Caído' then 2
                    when 'Sin actividad 2026' then 3
                    else 4 end,
                c.cliente_nombre),'[]'::json)
            from clientes_periodo c
            left join respuestas rp
                   on rp.periodo = c.periodo
                  and rp.vendedor_codigo = c.vendedor_codigo
                  and rp.cliente_codigo  = c.cliente_codigo
            where c.periodo = p and c.vendedor_codigo = v.codigo)
    ) into r;
    return r;
end; $$;

-- ------------------------------------------------------------
-- 5. FUNCION: guardar respuestas (lote)
-- ------------------------------------------------------------

create or replace function app_guardar(p_token text, p_items jsonb)
returns json
language plpgsql security definer set search_path = public as $$
declare
    v  vendedores%rowtype;
    p  text;
    it jsonb;
    n  int := 0;
begin
    select * into v from vendedores where token = p_token and activo = true;
    if not found then return json_build_object('error','token_invalido'); end if;

    select max(periodo) into p from clientes_periodo where vendedor_codigo = v.codigo;
    if p is null then return json_build_object('error','sin_periodo'); end if;

    for it in select * from jsonb_array_elements(p_items) loop
        if exists (select 1 from clientes_periodo c
                   where c.periodo = p and c.vendedor_codigo = v.codigo
                     and c.cliente_codigo = it->>'cliente_codigo') then
            insert into respuestas (periodo, vendedor_codigo, cliente_codigo, motivo_id, detalle)
            values (p, v.codigo, it->>'cliente_codigo', it->>'motivo_id',
                    nullif(it->>'detalle',''))
            on conflict (periodo, vendedor_codigo, cliente_codigo)
            do update set motivo_id = excluded.motivo_id,
                          detalle = excluded.detalle,
                          actualizado_en = now();
            n := n + 1;
        end if;
    end loop;
    return json_build_object('guardados', n, 'periodo', p);
end; $$;

-- ------------------------------------------------------------
-- 6. FUNCION: tablero de seguimiento
-- ------------------------------------------------------------

create or replace function app_avance(p_clave text, p_periodo text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
    p text;
    r json;
begin
    if p_clave is distinct from (select valor from config where clave = 'clave_seguimiento') then
        return json_build_object('error','clave_invalida');
    end if;

    p := coalesce(p_periodo, (select max(periodo) from clientes_periodo));
    if p is null then return json_build_object('error','sin_periodo'); end if;

    select json_build_object(
        'periodo', p,
        'periodos', (select coalesce(json_agg(distinct periodo),'[]'::json)
                     from clientes_periodo),
        'actualizado', now(),
        'vendedores', (
            select coalesce(json_agg(x order by x.avance, x.vendedor),'[]'::json) from (
                select v.nombre as vendedor,
                       coalesce(v.supervisor,'Sin supervisor') as supervisor,
                       count(*)::int as asignados,
                       count(rp.id)::int as cargados,
                       coalesce(round(100.0*count(rp.id)/nullif(count(*),0)),0)::int as avance,
                       max(rp.actualizado_en) as ultima_carga
                from clientes_periodo c
                join vendedores v on v.codigo = c.vendedor_codigo
                left join respuestas rp
                       on rp.periodo = c.periodo
                      and rp.vendedor_codigo = c.vendedor_codigo
                      and rp.cliente_codigo = c.cliente_codigo
                where c.periodo = p
                group by v.nombre, v.supervisor
            ) x),
        'motivos', (
            select coalesce(json_agg(y order by y.cantidad desc),'[]'::json) from (
                select m.etiqueta as motivo, count(*)::int as cantidad
                from respuestas rp join motivos m on m.id = rp.motivo_id
                where rp.periodo = p
                group by m.etiqueta
            ) y),
        'estados', (
            select coalesce(json_agg(z order by z.estado),'[]'::json) from (
                select coalesce(c.estado,'Sin estado') as estado,
                       count(*)::int as asignados,
                       count(rp.id)::int as cargados
                from clientes_periodo c
                left join respuestas rp
                       on rp.periodo = c.periodo
                      and rp.vendedor_codigo = c.vendedor_codigo
                      and rp.cliente_codigo = c.cliente_codigo
                where c.periodo = p
                group by coalesce(c.estado,'Sin estado')
            ) z),
        'sueltos', (
            select coalesce(json_agg(w order by w.cuando desc),'[]'::json) from (
                select v.nombre as vendedor, c.cliente_nombre as cliente,
                       m.etiqueta as motivo, rp.detalle,
                       rp.actualizado_en as cuando
                from respuestas rp
                join motivos m on m.id = rp.motivo_id
                join vendedores v on v.codigo = rp.vendedor_codigo
                join clientes_periodo c
                     on c.periodo = rp.periodo
                    and c.vendedor_codigo = rp.vendedor_codigo
                    and c.cliente_codigo = rp.cliente_codigo
                where rp.periodo = p and rp.detalle is not null
                order by rp.actualizado_en desc limit 40
            ) w)
    ) into r;
    return r;
end; $$;

-- ------------------------------------------------------------
-- 7. VISTA DE AVANCE
-- ------------------------------------------------------------

create or replace view v_avance as
select c.periodo, v.supervisor, c.vendedor_codigo, v.nombre as vendedor,
       count(*) as asignados,
       count(r.id) as cargados,
       count(*) - count(r.id) as pendientes,
       round(100.0*count(r.id)/nullif(count(*),0),1) as avance_pct,
       max(r.actualizado_en) as ultima_carga
from clientes_periodo c
join vendedores v on v.codigo = c.vendedor_codigo
left join respuestas r
       on r.periodo = c.periodo
      and r.vendedor_codigo = c.vendedor_codigo
      and r.cliente_codigo = c.cliente_codigo
group by c.periodo, v.supervisor, c.vendedor_codigo, v.nombre;
