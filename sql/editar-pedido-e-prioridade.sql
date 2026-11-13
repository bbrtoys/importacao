-- =====================================================================
-- Edição de pedidos, prioridade de fabricação por item e número sem data
-- Rodar uma vez no SQL Editor do Supabase (pode rodar de novo sem problema).
-- Este arquivo já inclui o conteúdo de numero-pedido-sem-data.sql.
--
-- Regras de edição:
--   * admin e interno (BBR Toys) editam qualquer pedido;
--   * o cliente edita só os pedidos que ele mesmo criou, até 04/12/2026 às
--     23:59 (horário de Brasília). Para mudar o prazo, troque a data em
--     editar_pedido abaixo e a constante PRAZO_EDICAO no index.html.
-- =====================================================================

-- ---------- prioridade de fabricação por item ----------
alter table public.pedido_itens
  add column if not exists prioridade boolean not null default false;

-- ---------- validação comum aos itens (criar e editar) ----------
create or replace function public.validar_itens_pedido(p_cliente uuid, p_itens jsonb)
returns void
language plpgsql stable security definer set search_path = public as $$
declare
  v_ruim text;
begin
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'Informe pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 5000 then
    raise exception 'O pedido aceita no máximo 5000 linhas.';
  end if;

  -- lojas informadas precisam ser do cliente do pedido
  if exists (
    select 1 from jsonb_array_elements(p_itens) t(item)
    where nullif(t.item->>'loja_id','') is not null
      and not exists (select 1 from public.lojas l
                      where l.id = (t.item->>'loja_id')::uuid and l.cliente_id = p_cliente)
  ) then
    raise exception 'Uma das lojas informadas não pertence a este cliente.';
  end if;

  -- itens do catálogo: só caixa master inteira ou meia caixa (vale por loja)
  select string_agg(coalesce(nullif(c.ref_china,''), c.id::text), ', ') into v_ruim
  from jsonb_array_elements(p_itens) t(item)
  join public.catalogo c on c.id = nullif(t.item->>'catalogo_id','')::integer
  where c.cx_master > 0 and ((t.item->>'qtd')::integer * 2) % c.cx_master <> 0;
  if v_ruim is not null then
    raise exception 'Quantidade fora da caixa master (aceita caixa inteira ou meia caixa): %', v_ruim;
  end if;
end $$;

-- ---------- grava os itens de um pedido ----------
create or replace function public.gravar_itens_pedido(p_pedido uuid, p_itens jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.pedido_itens (pedido_id, ordem, ref, produto, qtd, catalogo_id, loja_id, prioridade)
  select p_pedido, t.ord,
         left(coalesce(t.item->>'ref', ''), 40),
         left(coalesce(t.item->>'produto', ''), 200),
         (t.item->>'qtd')::integer,
         (select c.id from public.catalogo c where c.id = nullif(t.item->>'catalogo_id','')::integer),
         nullif(t.item->>'loja_id','')::uuid,
         coalesce((t.item->>'prioridade')::boolean, false)
  from jsonb_array_elements(p_itens) with ordinality as t(item, ord);
end $$;

-- ---------- criar pedido (agora com prioridade e número IMP0007) ----------
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
  if v_papel <> 'cliente' then
    raise exception 'Os pedidos são enviados pelos usuários dos clientes.';
  end if;
  v_cliente := public.meu_cliente();
  if v_cliente is null or not exists (select 1 from public.clientes where id = v_cliente and ativo) then
    raise exception 'Cliente inválido.';
  end if;
  -- no pedido novo, a loja também precisa estar ativa
  if exists (
    select 1 from jsonb_array_elements(p_itens) t(item)
    where nullif(t.item->>'loja_id','') is not null
      and not exists (select 1 from public.lojas l
                      where l.id = (t.item->>'loja_id')::uuid and l.cliente_id = v_cliente and l.ativo)
  ) then
    raise exception 'Uma das lojas informadas não pertence a este cliente.';
  end if;
  perform public.validar_itens_pedido(v_cliente, p_itens);

  v_numero := 'IMP' || lpad(nextval('public.pedido_seq')::text, 4, '0');

  insert into public.pedidos (numero, cliente_id, criado_por, responsavel, obs)
  values (v_numero, v_cliente, auth.uid(),
          left(coalesce(p_responsavel, ''), 80), left(coalesce(p_obs, ''), 1000))
  returning id into v_id;

  perform public.gravar_itens_pedido(v_id, p_itens);

  return jsonb_build_object('id', v_id, 'numero', v_numero);
end $$;

-- ---------- editar pedido ----------
create or replace function public.editar_pedido(p_pedido uuid, p_obs text, p_itens jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_papel text := public.meu_papel();
  v_ped public.pedidos%rowtype;
begin
  if v_papel is null or v_papel = 'pendente' then
    raise exception 'Seu usuário não tem permissão para editar pedidos.';
  end if;

  select * into v_ped from public.pedidos where id = p_pedido for update;
  if not found then
    raise exception 'Pedido não encontrado.';
  end if;

  if v_papel = 'cliente' then
    if v_ped.criado_por is distinct from auth.uid() then
      raise exception 'Você só pode editar os pedidos que você mesmo enviou.';
    end if;
    if now() >= (timestamp '2026-12-05 00:00' at time zone 'America/Sao_Paulo') then
      raise exception 'O prazo para editar pedidos terminou em 04/12/2026 às 23:59. Fale com a BBR Toys para alterar.';
    end if;
  elsif v_papel not in ('admin', 'interno') then
    raise exception 'Seu usuário não tem permissão para editar pedidos.';
  end if;

  perform public.validar_itens_pedido(v_ped.cliente_id, p_itens);

  delete from public.pedido_itens where pedido_id = p_pedido;
  perform public.gravar_itens_pedido(p_pedido, p_itens);

  update public.pedidos
     set obs = left(coalesce(p_obs, ''), 1000),
         atualizado_em = now()
   where id = p_pedido;

  return jsonb_build_object('id', v_ped.id, 'numero', v_ped.numero);
end $$;

-- ---------- permissões ----------
revoke all on function public.validar_itens_pedido(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.gravar_itens_pedido(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.criar_pedido(uuid, text, text, jsonb) from public, anon;
revoke all on function public.editar_pedido(uuid, text, jsonb) from public, anon;
grant execute on function public.criar_pedido(uuid, text, text, jsonb) to authenticated;
grant execute on function public.editar_pedido(uuid, text, jsonb) to authenticated;
