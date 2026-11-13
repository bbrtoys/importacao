const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
const names = [
  "fmtInt", "fmtRs", "catDe", "catItem", "itensVis", "filtrados",
  "caixasDoItem", "resumoCaixas", "resumoItens", "resumoPedidos"
];
const source = names.map((name) => {
  const match = html.match(new RegExp(`^        function ${name}\\([^]*?^        }`, "m"));
  assert.ok(match, `Função encontrada: ${name}`);
  return match[0];
}).join("\n");

function fixture() {
  const fields = {
    "fil-cliente": { value: "" },
    "fil-status": { value: "" },
    "fil-busca": { value: "" }
  };
  const context = vm.createContext({
    $: (id) => fields[id],
    pCats: {},
    ETAPAS_VISIVEIS: [
      ["recebido", "Recebido"], ["em_analise", "Em análise"], ["confirmado", "Confirmado"]
    ],
    cat: { porId: {
      pato: { preco: 22.37, cx_master: 162, categoria: "PELÚCIA" },
      carro: { preco: 9.07, cx_master: 432, categoria: "VEÍCULOS" },
      semPreco: { preco: null, categoria: "PELÚCIA" }
    } },
    pedidos: [
      { numero: "IMP-1", cliente_id: "a", status: "recebido", itens: [
        { catalogo_id: "pato", qtd: 81 }, { catalogo_id: "carro", qtd: 216 }
      ] },
      { numero: "IMP-2", cliente_id: "a", status: "confirmado", itens: [
        { catalogo_id: "pato", qtd: 162 }
      ] },
      { numero: "IMP-3", cliente_id: "b", status: "em_analise", itens: [
        { catalogo_id: "carro", qtd: 432 }, { catalogo_id: "semPreco", qtd: 100 }
      ] }
    ]
  });
  vm.runInContext(source, context);
  return { context, fields };
}

test("cartões totalizam os mesmos itens da tabela, sem duplicar valores entre etapas", () => {
  const { context: c } = fixture();
  const groups = c.resumoPedidos(c.filtrados());
  assert.deepEqual(Array.from(groups, (g) => g.quantidade), [3, 1, 1, 1]);
  assert.equal(c.fmtRs(groups[0].valor), "R$ 11.313,27");
  assert.equal(c.fmtRs(groups[1].valor), "R$ 3.771,09");
  assert.equal(c.fmtRs(groups[2].valor), "R$ 3.918,24");
  assert.equal(c.fmtRs(groups[3].valor), "R$ 3.623,94");
});

test("valores respeitam cliente, etapa e busca", () => {
  const { context: c, fields } = fixture();
  fields["fil-cliente"].value = "a";
  fields["fil-status"].value = "confirmado";
  fields["fil-busca"].value = "IMP-2";
  const groups = c.resumoPedidos(c.filtrados());
  assert.deepEqual(Array.from(groups, (g) => g.quantidade), [1, 0, 0, 1]);
  assert.equal(c.fmtRs(groups[0].valor), "R$ 3.623,94");
  assert.equal(c.fmtRs(groups[1].valor), "R$ 0,00");
  fields["fil-cliente"].value = "b";
  assert.ok(c.resumoPedidos(c.filtrados()).every((g) => g.quantidade === 0 && g.valor === 0));
});

test("categoria selecionada exclui do valor os demais itens do mesmo pedido", () => {
  const { context: c } = fixture();
  c.pCats = { "PELÚCIA": true };
  const groups = c.resumoPedidos(c.filtrados());
  assert.equal(groups[0].quantidade, 3);
  assert.equal(c.fmtRs(groups[0].valor), "R$ 5.435,91");
  assert.equal(c.fmtRs(groups[1].valor), "R$ 1.811,97");
  assert.equal(groups[2].valor, 0);
});

test("lista vazia mantém todos os cartões zerados", () => {
  const { context: c } = fixture();
  const groups = c.resumoPedidos([]);
  assert.equal(groups.length, 4);
  assert.ok(groups.every((g) => g.quantidade === 0 && g.valor === 0));
});

test("valores e quantidades grandes aparecem completos, com centavos nos valores", () => {
  const { context: c } = fixture();
  assert.equal(c.fmtRs(21946.17), "R$ 21.946,17");
  assert.equal(c.fmtRs(123456789.99), "R$ 123.456.789,99");
  assert.equal(c.fmtInt(123456789), "123.456.789");
});
