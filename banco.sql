-- =====================================================================
-- Sistema de Pedido de Importação - estrutura do banco (Supabase)
-- Rodar uma única vez no SQL Editor do projeto.
-- =====================================================================

-- ---------- Tabelas ----------
create table public.clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create table public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  nome text not null default '',
  papel text not null default 'pendente'
    check (papel in ('admin','interno','cliente','pendente')),
  cliente_id uuid references public.clientes(id),
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  constraint cliente_tem_empresa check (papel <> 'cliente' or cliente_id is not null)
);

create sequence public.pedido_seq;

create table public.pedidos (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  cliente_id uuid not null references public.clientes(id),
  criado_por uuid not null references public.perfis(id),
  responsavel text not null default '',
  obs text not null default '',
  status text not null default 'recebido'
    check (status in ('recebido','em_analise','confirmado','embarcado')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index pedidos_cliente_idx on public.pedidos (cliente_id, criado_em desc);

create table public.pedido_itens (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.pedidos(id) on delete cascade,
  ordem integer not null,
  ref text not null default '',
  produto text not null default '',
  qtd integer not null check (qtd > 0),
  constraint item_identificado check (ref <> '' or produto <> '')
);
create index pedido_itens_pedido_idx on public.pedido_itens (pedido_id);

-- ---------- Funções de apoio (quem é o usuário logado) ----------
create function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid() and ativo
$$;

create function public.meu_cliente() returns uuid
language sql stable security definer set search_path = public as $$
  select cliente_id from public.perfis
  where id = auth.uid() and ativo and papel = 'cliente'
$$;

create function public.sou_interno() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() in ('admin','interno'), false)
$$;

create function public.existe_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where papel = 'admin')
$$;

-- ---------- Perfil criado junto com cada usuário ----------
-- O primeiro usuário do sistema vira administrador; os demais ficam
-- pendentes até um administrador definir o perfil.
create function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (id, email, nome, papel)
  values (
    new.id, new.email,
    left(coalesce(new.raw_user_meta_data->>'nome', ''), 80),
    case when exists (select 1 from public.perfis where papel = 'admin')
         then 'pendente' else 'admin' end
  );
  return new;
end $$;

create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.novo_usuario();

-- ---------- Criação de pedido (pedido + itens numa única operação) ----------
create function public.criar_pedido(p_cliente uuid, p_responsavel text, p_obs text, p_itens jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_papel text := public.meu_papel();
  v_cliente uuid;
  v_id uuid;
  v_numero text;
begin
  if v_papel is null or v_papel = 'pendente' then
    raise exception 'Seu usuário não tem permissão para criar pedidos.';
  end if;
  if v_papel = 'cliente' then
    v_cliente := public.meu_cliente();
  else
    v_cliente := p_cliente;
  end if;
  if v_cliente is null or not exists (select 1 from public.clientes where id = v_cliente and ativo) then
    raise exception 'Cliente inválido.';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'Informe pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 1000 then
    raise exception 'O pedido aceita no máximo 1000 itens.';
  end if;

  v_numero := 'IMP-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYMMDD')
              || '-' || lpad(nextval('public.pedido_seq')::text, 4, '0');

  insert into public.pedidos (numero, cliente_id, criado_por, responsavel, obs)
  values (v_numero, v_cliente, auth.uid(),
          left(coalesce(p_responsavel, ''), 80), left(coalesce(p_obs, ''), 1000))
  returning id into v_id;

  insert into public.pedido_itens (pedido_id, ordem, ref, produto, qtd)
  select v_id, t.ord,
         left(coalesce(t.item->>'ref', ''), 40),
         left(coalesce(t.item->>'produto', ''), 200),
         (t.item->>'qtd')::integer
  from jsonb_array_elements(p_itens) with ordinality as t(item, ord);

  return jsonb_build_object('id', v_id, 'numero', v_numero);
end $$;

-- ---------- Segurança por linha (quem vê e altera o quê) ----------
alter table public.clientes     enable row level security;
alter table public.perfis       enable row level security;
alter table public.pedidos      enable row level security;
alter table public.pedido_itens enable row level security;

-- clientes: interno vê todos; cliente vê só a própria empresa; admin gerencia
create policy clientes_ler on public.clientes for select to authenticated
  using (public.sou_interno() or id = public.meu_cliente());
create policy clientes_incluir on public.clientes for insert to authenticated
  with check (public.meu_papel() = 'admin');
create policy clientes_alterar on public.clientes for update to authenticated
  using (public.meu_papel() = 'admin') with check (public.meu_papel() = 'admin');

-- perfis: cada um vê o próprio; interno vê todos; só admin altera
create policy perfis_ler on public.perfis for select to authenticated
  using (id = auth.uid() or public.sou_interno());
create policy perfis_alterar on public.perfis for update to authenticated
  using (public.meu_papel() = 'admin') with check (public.meu_papel() = 'admin');

-- pedidos: interno vê todos; cliente vê só os da própria empresa
create policy pedidos_ler on public.pedidos for select to authenticated
  using (public.sou_interno() or cliente_id = public.meu_cliente());
create policy pedidos_etapa on public.pedidos for update to authenticated
  using (public.sou_interno()) with check (public.sou_interno());
create policy pedidos_excluir on public.pedidos for delete to authenticated
  using (public.meu_papel() = 'admin');

-- itens: visíveis para quem enxerga o pedido
create policy itens_ler on public.pedido_itens for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id));

-- ---------- Permissões ----------
revoke all on public.clientes, public.perfis, public.pedidos, public.pedido_itens from anon, authenticated;
grant select on public.clientes, public.perfis, public.pedidos, public.pedido_itens to authenticated;
grant insert, update on public.clientes to authenticated;
grant update (nome, papel, cliente_id, ativo) on public.perfis to authenticated;
grant update (status, atualizado_em) on public.pedidos to authenticated;
grant delete on public.pedidos to authenticated;

revoke all on function public.criar_pedido(uuid, text, text, jsonb) from public, anon;
revoke all on function public.meu_papel(), public.meu_cliente(), public.sou_interno() from public, anon;
revoke all on function public.novo_usuario() from public, anon, authenticated;
grant execute on function public.criar_pedido(uuid, text, text, jsonb) to authenticated;
grant execute on function public.meu_papel(), public.meu_cliente(), public.sou_interno() to authenticated;
grant execute on function public.existe_admin() to anon, authenticated;

-- ---------- Clientes de importação ----------
insert into public.clientes (nome) values
  ('BUMERANG'), ('PIRLIMPIMPIM'), ('ESTRIPULIA'), ('KIMANIA'), ('B DA HORA'),
  ('TOY BOY'), ('BIG FESTA'), ('PIRUETA'), ('BRINQUEDOLÂNDIA'), ('SUPERLEGAL');

-- =====================================================================
-- Dashboard de itens: mínimos para importação por código + tempo real
-- =====================================================================
create table public.produtos (
  ref text primary key check (ref <> '' and ref = upper(btrim(ref))),
  descricao text not null default '',
  minimo integer not null default 0 check (minimo >= 0),
  atualizado_em timestamptz not null default now()
);
alter table public.produtos enable row level security;
create policy produtos_ler on public.produtos for select to authenticated
  using (public.sou_interno());
create policy produtos_incluir on public.produtos for insert to authenticated
  with check (public.sou_interno());
create policy produtos_alterar on public.produtos for update to authenticated
  using (public.sou_interno()) with check (public.sou_interno());
create policy produtos_excluir on public.produtos for delete to authenticated
  using (public.meu_papel() = 'admin');
revoke all on public.produtos from anon, authenticated;
grant select, insert, update, delete on public.produtos to authenticated;

alter publication supabase_realtime add table public.pedidos, public.pedido_itens, public.produtos;
-- =====================================================================
-- Catálogo de importação (planilha Portal BBR Toys Importação 2027)
-- =====================================================================
create table public.catalogo (
  id integer primary key,
  ordem integer not null default 0,
  showroom text not null default '',
  ref_china text not null default '',
  ref_brasil text not null default '',
  ref_final text not null default '',
  descricao_original text not null default '',
  descricao text not null default '',
  categoria text not null default '',
  subcategoria text not null default '',
  fob numeric,
  preco numeric,
  pack text not null default '',
  cx_master integer,
  display text not null default '',
  info text not null default '',
  inner_qtd integer,
  dim_cx text not null default '',
  dim_produto text not null default '',
  cbm text not null default '',
  cuft text not null default '',
  gw text not null default '',
  nw text not null default '',
  imagem text not null default '',
  ativo boolean not null default true,
  atualizado_em timestamptz not null default now()
);
create index catalogo_categoria_idx on public.catalogo (categoria, ordem);
alter table public.catalogo enable row level security;
create policy catalogo_ler on public.catalogo for select to authenticated
  using (coalesce(public.meu_papel() in ('admin','interno','cliente'), false));
create policy catalogo_incluir on public.catalogo for insert to authenticated
  with check (public.meu_papel() = 'admin');
create policy catalogo_alterar on public.catalogo for update to authenticated
  using (public.meu_papel() = 'admin') with check (public.meu_papel() = 'admin');
create policy catalogo_excluir on public.catalogo for delete to authenticated
  using (public.meu_papel() = 'admin');
revoke all on public.catalogo from anon, authenticated;
grant select, insert, update, delete on public.catalogo to authenticated;

-- imagens do catálogo (bucket privado: só usuários logados e liberados veem)
insert into storage.buckets (id, name, public) values ('catalogo', 'catalogo', false)
  on conflict (id) do nothing;
create policy catalogo_img_ler on storage.objects for select to authenticated
  using (bucket_id = 'catalogo' and coalesce(public.meu_papel() in ('admin','interno','cliente'), false));
create policy catalogo_img_incluir on storage.objects for insert to authenticated
  with check (bucket_id = 'catalogo' and public.meu_papel() = 'admin');
create policy catalogo_img_alterar on storage.objects for update to authenticated
  using (bucket_id = 'catalogo' and public.meu_papel() = 'admin') with check (bucket_id = 'catalogo' and public.meu_papel() = 'admin');
create policy catalogo_img_excluir on storage.objects for delete to authenticated
  using (bucket_id = 'catalogo' and public.meu_papel() = 'admin');

-- itens de pedido passam a guardar de qual linha do catálogo vieram
alter table public.pedido_itens add column catalogo_id integer references public.catalogo(id) on delete set null;

create or replace function public.criar_pedido(p_cliente uuid, p_responsavel text, p_obs text, p_itens jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_papel text := public.meu_papel();
  v_cliente uuid;
  v_id uuid;
  v_numero text;
begin
  if v_papel is null or v_papel = 'pendente' then
    raise exception 'Seu usuário não tem permissão para criar pedidos.';
  end if;
  if v_papel = 'cliente' then
    v_cliente := public.meu_cliente();
  else
    v_cliente := p_cliente;
  end if;
  if v_cliente is null or not exists (select 1 from public.clientes where id = v_cliente and ativo) then
    raise exception 'Cliente inválido.';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'Informe pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 1500 then
    raise exception 'O pedido aceita no máximo 1500 itens.';
  end if;

  v_numero := 'IMP-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYMMDD')
              || '-' || lpad(nextval('public.pedido_seq')::text, 4, '0');

  insert into public.pedidos (numero, cliente_id, criado_por, responsavel, obs)
  values (v_numero, v_cliente, auth.uid(),
          left(coalesce(p_responsavel, ''), 80), left(coalesce(p_obs, ''), 1000))
  returning id into v_id;

  insert into public.pedido_itens (pedido_id, ordem, ref, produto, qtd, catalogo_id)
  select v_id, t.ord,
         left(coalesce(t.item->>'ref', ''), 40),
         left(coalesce(t.item->>'produto', ''), 200),
         (t.item->>'qtd')::integer,
         (select c.id from public.catalogo c where c.id = nullif(t.item->>'catalogo_id','')::integer)
  from jsonb_array_elements(p_itens) with ordinality as t(item, ord);

  return jsonb_build_object('id', v_id, 'numero', v_numero);
end $$;

-- =====================================================================
-- Colunas visíveis do catálogo (definidas pela importação: células verdes)
-- =====================================================================
alter table public.catalogo add column if not exists moq integer;
create table if not exists public.config (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);
alter table public.config enable row level security;
create policy config_ler on public.config for select to authenticated
  using (coalesce(public.meu_papel() in ('admin','interno','cliente'), false));
create policy config_incluir on public.config for insert to authenticated
  with check (public.meu_papel() = 'admin');
create policy config_alterar on public.config for update to authenticated
  using (public.meu_papel() = 'admin') with check (public.meu_papel() = 'admin');
revoke all on public.config from anon, authenticated;
grant select, insert, update on public.config to authenticated;

-- criar_pedido passou a recusar itens do catálogo fora de caixa inteira ou meia caixa:
--   ((qtd * 2) % cx_master) <> 0  ->  erro "Quantidade fora da caixa master ..."
