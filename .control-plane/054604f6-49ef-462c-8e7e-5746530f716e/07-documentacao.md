# Documentação e resumo — Logo original do PipeMaestro

## ADR
Nenhuma ADR nova: a identidade visual é decisão de produto, e o posicionamento
agnóstico de agente já está na [ADR 0019](../../docs/adr/0019-o-nome-pipemaestro.md).
O guia de UI registra o conceito e as regras. Nenhuma ADR anterior muda; o índice em
`docs/README.md` fica como está.

## Docs atualizados
- `docs/guias/ui-petal.md`: seção "Marca" (conceito, componentes, arquivos, regras), mais os
  test ids `brand`/`brand-mark` e o attr `testid` para a segunda marca da página.
- `e2e/README.md`: test ids da marca na convenção de nomes.
- Specs (`docs/specs/`) e roadmap: sem mudança.

## Resumo para quem revisa

### O que mudou e por quê, por app
- **`pipe_maestro_web`**: a marca deixou de ser um Heroicon (`hero-musical-note`) num
  quadrado e passou a ser um símbolo próprio, sem vínculo com fornecedor de agente:
  três agentes convergindo num pipeline que passa por uma etapa e termina no PR.
  - `BrandComponents.logo_mark/1` (novo) desenha o SVG inline. O fundo é CSS, e os traços
    usam `currentColor`, então duas marcas na mesma página não disputam ids de gradiente.
  - `Layouts.brand/1` usa o símbolo, tem `data-testid` `brand`/`brand-mark` e o attr `testid`
    para o rodapé.
  - Estáticos novos em `priv/static/images/` (`logo-mark.svg`, `logo-mark-mono.svg`,
    `favicon.svg`) e `priv/static/favicon.ico` regenerado.
  - `root.html.heex` declara os dois ícones.
- **`pipe_maestro`, `pipe_maestro_protocol`, `pipe_maestro_runner`**: sem mudanças.

### Protocolo
Não mudou, e a versão não sobe. Runners antigos não são afetados.

### Riscos e o que olhar
- O `.ico` foi gerado com `qlmanage` e Pillow; os cantos foram recortados com máscara.
  Confira a aba do navegador (Safari/Chrome antigo usam o `.ico`).
- Legibilidade em 16 px: o `favicon.svg` é um desenho simplificado de propósito.
- "Powered by Claude" no rodapé da landing continua (texto fora do escopo); decida se fica
  num acompanhamento.
- Screenshots e2e existentes mudam de aparência (esperado).

### Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?` → 0.
- `make e2e` (ou `make e2e FILE=tests/public-pages.spec.ts`) e `make e2e.shots` para ver
  claro e escuro.
- Na tela: landing (nav e rodapé), `/login`, login do backoffice, seletor de workspace,
  ativação de runner, sidebar do app (recolhida: só o nome some) e a aba do navegador.
