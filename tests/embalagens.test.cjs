const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");
const names = [
  "fmtInt",
  "caixasDoItem",
  "resumoCaixas",
  "fmtCaixas",
  "resumoItens",
  "passoCx",
  "qtdValida",
  "textoCx",
  "baixarPedidosXlsx"
];
const source = names
  .map((name) => {
    const match = html.match(
      new RegExp(`^        function ${name}\\([^]*?^        }`, "m")
    );
    assert.ok(match, `Funcao encontrada: ${name}`);
    return match[0];
  })
  .join("\n");
const context = vm.createContext({
  cat: {
    porId: {
      pato: { cx_master: 162, preco: 22.37 },
      capivara: { cx_master: 432, preco: 9.07 }
    }
  },
  lojaPorId: () => null,
  fmtData: () => "12/11/2026",
  etapaNome: () => "Recebido",
  catDe: () => "PELÚCIA",
  baixarXlsx: (nome, folha, cols, linhas) => ({ cols, linhas })
});
vm.runInContext(source, context);
const itens = [
  { catalogo_id: "pato", qtd: 81 },
  { catalogo_id: "capivara", qtd: 216 }
];

test("meias caixas de dois produtos nunca viram uma caixa inteira", () => {
  const r = context.resumoItens(itens);
  assert.equal(r.n, 2);
  assert.equal(r.un, 297);
  assert.equal(r.caixas.inteiras, 0);
  assert.equal(r.caixas.meias, 2);
  assert.equal(context.fmtCaixas(r.caixas), "2 meias caixas");
  assert.ok(Math.abs(r.valor - (81 * 22.37 + 216 * 9.07)) < 0.000001);
  for (const i of itens)
    assert.equal(
      context.textoCx(context.cat.porId[i.catalogo_id], i.qtd).t,
      "1 meia caixa"
    );
});

test("separa caixas inteiras e meias caixas sem arredondar unidades", () => {
  const r = context.resumoCaixas([
    { catalogo_id: "pato", qtd: 243 },
    { catalogo_id: "capivara", qtd: 648 }
  ]);
  assert.equal(context.fmtCaixas(r), "2 caixas inteiras + 2 meias caixas");
  assert.equal(
    context.fmtCaixas(context.caixasDoItem({ cx_master: 162 }, 324)),
    "2 caixas inteiras"
  );
  assert.equal(context.fmtCaixas(context.resumoCaixas([])), "0 caixas");
});

test("mantem separadas as meias caixas destinadas a lojas diferentes", () => {
  const r = context.resumoCaixas([
    { catalogo_id: "pato", qtd: 81, loja_id: "a" },
    { catalogo_id: "pato", qtd: 81, loja_id: "b" }
  ]);
  assert.equal(context.fmtCaixas(r), "2 meias caixas");
});

test("quantidade invalida e embalagem ausente nao sao tratadas como meia caixa", () => {
  assert.equal(context.textoCx({ cx_master: 162 }, 80).fora, true);
  assert.equal(
    context.fmtCaixas(context.caixasDoItem({ cx_master: 162 }, 80)),
    "1 caixa parcial"
  );
  assert.equal(
    context.fmtCaixas(context.caixasDoItem(null, 81)),
    "1 item sem embalagem informada"
  );
  assert.equal(context.qtdValida({ cx_master: 9 }, 4), false);
  assert.equal(context.qtdValida({ cx_master: 9 }, 9), true);
});

test("Excel exporta quantidades de caixas inteiras e meias em colunas separadas", () => {
  const result = context.baixarPedidosXlsx("teste.xlsx", [{ itens }]);
  const index = (label) => result.cols.findIndex((c) => c[0] === label);
  assert.equal(result.linhas.length, 2);
  for (const row of result.linhas) {
    assert.equal(row.length, result.cols.length);
    assert.equal(row[index("Caixas inteiras")], 0);
    assert.equal(row[index("Meias caixas (separadas por produto)")], 1);
    assert.equal(row[index("Embalagem por item")], "1 meia caixa");
  }
  assert.equal(
    result.linhas.reduce((n, row) => n + row[index("Quantidade")], 0),
    297
  );
});
