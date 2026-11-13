-- =====================================================================
-- Total de unidades já pedidas por item do catálogo (soma de todos os
-- clientes), para mostrar no pedido quanto falta para atingir o MOQ.
-- Rodar uma vez no SQL Editor do Supabase (pode rodar de novo sem problema).
--
-- Devolve só o total por item: o cliente não vê quem pediu nem quanto
-- cada cliente pediu.
-- =====================================================================

create or replace function public.unidades_por_item()
returns table (catalogo_id integer, unidades bigint)
language sql stable security definer set search_path = public as $$
  select i.catalogo_id, sum(i.qtd)::bigint as unidades
  from public.pedido_itens i
  where i.catalogo_id is not null
    and coalesce(public.meu_papel() in ('admin', 'interno', 'cliente'), false)
  group by i.catalogo_id
$$;

revoke all on function public.unidades_por_item() from public, anon;
grant execute on function public.unidades_por_item() to authenticated;
