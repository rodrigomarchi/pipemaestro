# Telas (e2e)

A tarefa mudou telas (landing, `landing_shot`, specs e diretor em `e2e/`).

## Execução
- `make e2e`: saiu com 0, todos os specs passaram.
- `make e2e.shots FILE=tests/public-pages.spec.ts`, claro e `-dark`.

## Telas e estados conferidos
- Landing (desktop e celular): hero com o board real, tour `#produto` com as seis telas, header, diagramas e CTA final.
- Login e marca das páginas públicas.
- Hero e tour em celular: sem rolagem horizontal, textos sem corte.
- Contraste e consistência com as telas vizinhas: sem problemas.

## Ajuste
- As imagens `lazy` (principalmente as do outro tema) saíam em branco nas capturas escuras do tour e da landing inteira. O spec `e2e/tests/public-pages.spec.ts` ganhou `loadAllShots`, que força o carregamento e a decodificação das imagens antes de fotografar.
- O header fixo que aparece no meio das capturas de página inteira é efeito do sticky na captura, não defeito da tela.
