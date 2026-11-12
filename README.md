# Pedido de Importação — BBR Toys

Sistema web para os clientes de importação montarem pedidos a partir do catálogo, e para a equipe da BBR Toys acompanhar os pedidos e os mínimos de importação por item.

- **Site:** publicado pelo GitHub Pages a partir da branch principal deste repositório.
- **Banco, login e arquivos:** Supabase (projeto "Sistema Importação").

## Arquivos

| Arquivo | O que é |
|---|---|
| `index.html` | O sistema inteiro: telas, estilos e código JavaScript num arquivo só. |
| `assets/` | Logo BBR, mascote (urso com chapéu chinês) e fundos. |
| `banco.sql` | Registro de tudo o que foi executado no Supabase: tabelas, regras de acesso (RLS), funções, buckets de arquivos e clientes iniciais. Já está aplicado; serve de referência ou para recriar o banco do zero. |

## Como rodar no computador

O site é um arquivo HTML estático e não precisa de instalação nem de build.

1. Abra a pasta no VS Code.
2. Instale a extensão **Live Server** (Ritwick Dey).
3. Clique com o botão direito em `index.html` → **Open with Live Server**.

Rodando local, o site usa o **mesmo banco de produção** do Supabase. Pedidos, usuários e mudanças feitas nos testes valem de verdade.

## Como publicar uma alteração

```bash
git add -A
git commit -m "descreva a mudança"
git push
```

O GitHub Pages atualiza o site em 1 a 2 minutos. Se a versão antiga continuar aparecendo, recarregue com Ctrl + F5.

## Onde fica cada parte no `index.html`

Procure (Ctrl + F) pelos títulos em comentário:

- `CATÁLOGO`: tabela do novo pedido, filtros, categorias e regra de caixa inteira ou meia caixa.
- `LOGOS E LOJAS`: logos de clientes e lojas, e o pedido multiloja.
- `IMPORTAÇÃO DA PLANILHA (admin)`: leitura do .xlsx do portal (colunas verdes, imagens).
- `recibo, cópia e Excel`: geração dos arquivos .xlsx.
- `function renderPainel`: tela de pedidos (planilha expansível).
- `function renderDashboard`: dashboard de itens e gráficos.

Configuração do Supabase: `SUPABASE_URL` e `SUPABASE_KEY` no topo do script. A chave é a pública (publishable), feita para ficar no navegador. A segurança vem das regras de acesso do banco.

## Perfis de acesso

- **Administrador:** tudo, incluindo cadastro de usuários, clientes, lojas, logos e importação do catálogo.
- **BBR Toys (interno):** vê todos os pedidos, muda etapas e usa o dashboard.
- **Cliente:** faz pedidos só para o próprio cliente e vê só os pedidos dele.
