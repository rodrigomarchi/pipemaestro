# Entrega — Logo original do PipeMaestro

## Estado da branch
- Branch: `cp/criar-o-logo-original-do-pipemaestro-em-054604f6` (confirmada, não é `main`).
- `origin/main` (`b3f40b8`) já é ancestral da branch: `git log HEAD..origin/main` vazio.
  Não houve merge, então não foi preciso rodar `make ci` de novo nesta etapa.
- Árvore de trabalho limpa antes do commit deste artefato. Nenhum log ou screenshot
  solto foi encontrado.
- Nada foi empurrado nem PR aberto aqui: a plataforma faz o push e marca o PR.

## Commits (`origin/main..HEAD`, do mais antigo ao mais recente)
- `00ea7bc` Entendimento e plano: Criar o logo original do PipeMaestro em SVG, agnóstico de agente, e aplicá-lo na marca, no favicon e nas telas públicas
- `7d9cd4f` Testes que falham: logo do PipeMaestro na marca, nos SVGs estáticos e no favicon
- `4d1272d` Logo do PipeMaestro: BrandComponents.logo_mark/1 na marca, com test ids
- `d36762a` Logo do PipeMaestro em SVG estático, favicon SVG e .ico regenerado
- `40ec162` Guia de UI: seção Marca, com o conceito, os arquivos e as regras do logo
- `e229804` Implementação: logo do PipeMaestro na marca, no favicon e nas telas públicas
- `21f02fc` Revisão: test ids distintos para a marca do rodapé, sem .first() na spec e2e
- `25bf84e` CI verde: Criar o logo original do PipeMaestro em SVG, agnóstico de agente, e aplicá-lo na marca, no favicon e nas telas públicas
- `695e3bd` Spec e2e: o símbolo do rodapé é conferido pelo seu próprio test id
- `e4a4c1b` Documentação: test ids da marca no guia de UI e no README do e2e, resumo para revisão

Todas as mensagens estão em português e descrevem a mudança.
Diff contra `origin/main`: 20 arquivos, 675 inserções e 10 remoções.

## Resumo para quem revisa o PR

Resumo da etapa de Documentação (`07-documentacao.md`):

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

### Docs
- `docs/guias/ui-petal.md`: seção "Marca" (conceito, componentes, arquivos, regras).
- `e2e/README.md`: test ids da marca na convenção de nomes.
- Nenhuma ADR nova: a decisão agnóstica de agente já está na ADR 0019.
- Specs (`docs/specs/`) e roadmap: sem mudança.

### Protocolo
Não mudou, e a versão não sobe. Runners antigos não são afetados.

### Riscos e o que olhar
- O `.ico` foi gerado com `qlmanage` e Pillow; os cantos foram recortados com máscara.
  Confira a aba do navegador (Safari e Chrome antigo usam o `.ico`).
- Legibilidade em 16 px: o `favicon.svg` é um desenho simplificado de propósito.
- "Powered by Claude" no rodapé da landing continua (texto fora do escopo); decidir se
  fica em acompanhamento.
- Screenshots e2e existentes mudam de aparência (esperado).

### Como verificar
- `make ci > /tmp/ci.log 2>&1; echo $?` → 0 (registrado em `05-ci.md`).
- `make e2e` (ou `make e2e FILE=tests/public-pages.spec.ts`) e `make e2e.shots` para ver
  claro e escuro.
- Na tela: landing (nav e rodapé), `/login`, login do backoffice, seletor de workspace,
  ativação de runner, sidebar do app (recolhida: só o nome some) e a aba do navegador.

## Pendências para a revisão humana
- Conferir o `.ico` na aba do navegador.
- Decidir sobre o "Powered by Claude" no rodapé da landing (acompanhamento).

Status: ok. Branch pronta para a plataforma fazer o push e marcar o PR como pronto.
