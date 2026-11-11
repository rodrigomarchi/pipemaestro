/**
 * The workspace the landing director builds: names a visitor reads as a real
 * team's, and the code the runner works on (`loja-api`, an online store's API).
 */
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export const workspace = { name: "Nimbus", slug: "nimbus" };
export const member = { name: "Marina Costa", email: "marina@nimbus.dev" };
export const runnerName = "macbook-marina";
export const directory = "loja-api";
/** The store's repository on the Nimbus Forgejo, and the issue a label takes to a PR. */
export const repository = "nimbus/loja-api";
export const issue = {
  number: 42,
  title: "Cupom vencido ainda dá desconto",
  body: "O cupom BEMVINDO10 venceu ontem, mas o checkout ainda aplicou o desconto hoje de manhã.",
  labels: ["pipemaestro"],
};

/**
 * One task of the scenario. `phrase` is a sentence of its description that
 * picks its scene in the showcase CLI; `behaviour` is that scene ("ok",
 * "perguntas", "segura:<stage>" or "erra:implementacao", several
 * separated by spaces), and `module` the code under lib/loja/ the
 * task is about.
 */
export type ShowcaseTask = {
  title: string;
  prompt: string;
  phrase: string;
  behaviour: string;
  module: string;
};

export const tasks = {
  coupon: {
    title: "Corrigir arredondamento do total com cupom",
    prompt:
      "Pedidos com cupom de 10% mostram R$ 189,91 no checkout e R$ 189,90 na fatura. O total deve bater nos dois lugares.",
    phrase: "cupom de 10%",
    behaviour: "segura:investigacao erra:implementacao",
    module: "pedidos/total",
  },
  shipping: {
    title: "Frete grátis não aplica acima de R$ 200",
    prompt: "Carrinhos de exatamente R$ 200,00 ainda cobram frete; a regra diz a partir de R$ 200.",
    phrase: "ainda cobram frete",
    behaviour: "ok",
    module: "frete/regras",
  },
  pagination: {
    title: "Paginar a listagem de clientes",
    prompt: "A listagem de clientes carrega todos os registros de uma vez e passa de 8 s com 40 mil clientes.",
    phrase: "40 mil clientes",
    behaviour: "segura:implementacao",
    module: "clientes/listagem",
  },
  stock: {
    title: "Estoque negativo em compras simultâneas",
    prompt: "Duas compras ao mesmo tempo do último item deixam o estoque em -1.",
    phrase: "último item",
    behaviour: "segura:reproducao",
    module: "estoque/reserva",
  },
  export: {
    title: "Exportar pedidos em CSV",
    prompt: "O financeiro precisa baixar os pedidos do mês para conciliar com o banco.",
    phrase: "conciliar com o banco",
    behaviour: "perguntas",
    module: "pedidos/exportacao",
  },
} satisfies Record<string, ShowcaseTask>;

/** The scene map the showcase CLI reads (`SHOWCASE_SCENES`), one line per task. */
export function writeScenes(path: string): void {
  const lines = Object.values(tasks).map((t) => `${t.phrase}|${t.behaviour}|${t.module}`);
  writeFileSync(path, `${lines.join("\n")}\n`);
}

const moduleName = (path: string) =>
  path
    .split("/")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(".");

/** A module of the store, with the line the showcase CLI's fix edits. */
function libSource(path: string): string {
  return `defmodule Loja.${moduleName(path)} do
  @moduledoc false

  @arredondamento :por_item

  def calcular(pedido) do
    pedido.itens
    |> Enum.map(&valor(&1, @arredondamento))
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp valor(item, :por_item), do: Decimal.round(item.preco, 2)
  defp valor(item, :no_total), do: item.preco
end
`;
}

function testSource(path: string): string {
  return `defmodule Loja.${moduleName(path)}Test do
  use ExUnit.Case, async: true

  alias Loja.${moduleName(path)}

  @pedido %{itens: [%{preco: Decimal.new("99.95")}, %{preco: Decimal.new("89.95")}]}

  test "soma os itens" do
    assert ${moduleName(path).split(".").pop()}.calcular(@pedido)
  end
end
`;
}

// Prints what `mix test` prints; fails while a test written for a bug still
// meets the code that has it.
const testScript = `#!/bin/sh
fail=0
for t in $(find test -name '*_test.exs'); do
  m=\${t#test/}
  m=lib/\${m%_test.exs}.ex
  if grep -q 'soma antes de arredondar' "$t" && grep -q '@arredondamento :por_item' "$m"; then
    fail=$((fail + 1))
    failing=$(sed -n 's/^defmodule \\([A-Za-z.]*\\) do$/\\1/p' "$t")
  fi
done
echo "Compiling 14 files (.ex)"
echo "Generated loja app"
echo "Running ExUnit with seed: 401273, max_cases: 16"
echo
if [ "$fail" -gt 0 ]; then
  echo "  1) test soma antes de arredondar ($failing)"
  echo "     Assertion with == failed"
  echo "     left:  Decimal.new(\\"189.91\\")"
  echo "     right: Decimal.new(\\"189.90\\")"
  echo
  echo "Finished in 1.4 seconds (0.5s async, 0.9s sync)"
  echo "48 tests, $fail failure"
  exit 1
fi
echo "................................................"
echo "Finished in 1.3 seconds (0.4s async, 0.9s sync)"
echo "48 tests, 0 failures"
`;

/**
 * Creates the runner's code root with `loja-api`: a git repository with the
 * store's modules, their tests, a Makefile whose `test` prints a suite's output,
 * and installed dependencies git does not carry.
 */
export function createCodeRoot(root: string): string {
  const repo = join(root, directory);
  const write = (path: string, content: string) => {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    writeFileSync(join(repo, path), content);
  };

  write(
    "README.md",
    "# loja-api\n\nA API da loja online: catálogo, carrinho, pedidos, frete e estoque.\n\n" +
      "## Rodando\n\n    make deps\n    make test\n",
  );
  write(
    "mix.exs",
    'defmodule Loja.MixProject do\n  use Mix.Project\n\n  def project, do: [app: :loja, version: "1.4.0"]\nend\n',
  );
  write(
    "Makefile",
    ".PHONY: deps test lint\n\ndeps:\n\t@echo \"Todas as dependências estão atualizadas.\"\n\n" +
      "test:\n\t@sh bin/test\n\nlint:\n\t@echo \"Checking 31 source files ...\"\n" +
      "\t@echo \"Analysis took 0.4 seconds. 112 mods/funs, found no issues.\"\n",
  );
  write("bin/test", testScript);
  chmodSync(join(repo, "bin/test"), 0o755);
  write(".gitignore", "/deps\n/_build\n");

  for (const task of Object.values(tasks)) {
    write(`lib/loja/${task.module}.ex`, libSource(task.module));
    write(`test/loja/${task.module}_test.exs`, testSource(task.module));
  }
  write("lib/loja/pedidos.ex", "defmodule Loja.Pedidos do\n  @moduledoc false\nend\n");

  const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { stdio: "ignore" });
  const author = ["-c", "user.email=marina@nimbus.dev", "-c", "user.name=Marina Costa"];
  git("init", "-q", "-b", "main");
  git("add", ".");
  git(...author, "commit", "-q", "-m", "Catálogo, carrinho e pedidos");

  mkdirSync(join(repo, "deps", "decimal"), { recursive: true });
  writeFileSync(join(repo, "deps", "decimal", "mix.exs"), "decimal\n");
  return root;
}
