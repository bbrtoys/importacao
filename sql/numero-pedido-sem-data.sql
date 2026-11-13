-- =====================================================================
-- Número do pedido sem a data e sem hífen: IMP0007 em vez de IMP-261113-0007.
-- Rodar uma vez no SQL Editor do Supabase.
-- Só muda os pedidos novos; os antigos continuam gravados com a data
-- (o site já os exibe como IMP0007). A sequência continua a mesma,
-- então não há número repetido.
-- =====================================================================

create or replace function public.criar_pedido(p_cliente uuid, p_responsavel text, p_obs text, p_itens jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_papel text := public.meu_papel();
  v_cliente uuid;
  v_id uuid;
  v_numero text;
  v_ruim text;
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
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'Informe pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 5000 then
    raise exception 'O pedido aceita no máximo 5000 linhas.';
  end if;

  -- lojas informadas precisam ser do próprio cliente
  if exists (
    select 1 from jsonb_array_elements(p_itens) t(item)
    where nullif(t.item->>'loja_id','') is not null
      and not exists (select 1 from public.lojas l
                      where l.id = (t.item->>'loja_id')::uuid and l.cliente_id = v_cliente and l.ativo)
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

  v_numero := 'IMP' || lpad(nextval('public.pedido_seq')::text, 4, '0');

  insert into public.pedidos (numero, cliente_id, criado_por, responsavel, obs)
  values (v_numero, v_cliente, auth.uid(),
          left(coalesce(p_responsavel, ''), 80), left(coalesce(p_obs, ''), 1000))
  returning id into v_id;

  insert into public.pedido_itens (pedido_id, ordem, ref, produto, qtd, catalogo_id, loja_id)
  select v_id, t.ord,
         left(coalesce(t.item->>'ref', ''), 40),
         left(coalesce(t.item->>'produto', ''), 200),
         (t.item->>'qtd')::integer,
         (select c.id from public.catalogo c where c.id = nullif(t.item->>'catalogo_id','')::integer),
         nullif(t.item->>'loja_id','')::uuid
  from jsonb_array_elements(p_itens) with ordinality as t(item, ord);

  return jsonb_build_object('id', v_id, 'numero', v_numero);
end $$;
