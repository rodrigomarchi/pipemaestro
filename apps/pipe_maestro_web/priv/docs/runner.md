O runner é o executável que roda o agente na sua máquina. Ele **abre a conexão** com a
plataforma: nenhuma porta de entrada precisa ficar aberta na sua rede, e o código nunca
sai de lá.

## Baixar

Em **Executores → Conectar runner** há um executável por plataforma: macOS (Apple Silicon
e Intel) e Linux (x86_64 e arm64). Não há nada a instalar antes. Pelo terminal, o macOS
não pede para liberar o app:

```bash
mkdir -p ~/.local/bin
curl -fL https://app.pipemaestro.dev/downloads/runner/pipemaestro_macos_arm64 -o ~/.local/bin/pipemaestro
chmod +x ~/.local/bin/pipemaestro
```

Troque `macos_arm64` pelo seu alvo: `macos_x86_64`, `linux_x86_64` ou `linux_arm64`.

## Entrar e ligar

```bash
pipemaestro login --url https://app.pipemaestro.dev
pipemaestro start --root ~/src
```

O `login` mostra um código de oito letras para você confirmar no navegador; o `start` deixa o
runner online, esperando trabalho.

- `--root` é a pasta cujos diretórios o runner oferece aos projetos. A escolha fica
  guardada: da próxima vez, basta `pipemaestro start`.
- O login guarda a credencial do runner na máquina. Revogar o runner na página dele
  desconecta o executável na hora.

## Deixar ligado como serviço

Para o runner voltar sozinho depois de um reboot:

```bash
pipemaestro service install
pipemaestro service uninstall
```

No macOS ele vira um agente do launchd; no Linux, uma unidade de usuário do systemd.
`pipemaestro service print` mostra o arquivo sem instalar.

## Diagnóstico e estado

```bash
pipemaestro status
pipemaestro doctor
pipemaestro logout
```

O `status` diz se o runner está conectado e com qual credencial. O `doctor` confere o CLI do
agente e o login dele, o git, o `gh`, a pasta raiz, o disco livre e se a plataforma responde.
O `gh` (GitHub CLI) só é preciso nos pipelines que entregam um pull request. O runner roda
o `doctor` sozinho ao conectar. Se falta algo (o CLI do agente, por
exemplo), ele aparece **degradado** na lista e no board, e a aba **Diagnóstico** da página
dele diz o quê. A página também mostra:

- **Saúde**: CPU, memória, carga e disco livre, como o runner reporta.
- **Conexões**: cada conexão, quanto durou e por que terminou, e o uptime da semana.
- **Eventos e logs**: o log do próprio runner, ao vivo.

## Atualização automática

A plataforma exige uma versão do runner. Uma versão diferente se atualiza sozinha ao entrar
ou ligar. Com `--no-auto-update`, o runner pergunta antes de baixar a nova versão.

## Várias tarefas e várias máquinas

- Cada tarefa roda num **worktree git** próprio, com o próprio branch, então várias rodam
  ao mesmo tempo sem se atrapalhar. A capacidade do runner diz quantas.
- O runner prepara o worktree com o comando de setup do projeto, e o mantém entre as
  etapas da tarefa. Ao terminar, você pode removê-lo; o branch fica.
- Um runner parado no meio de uma etapa volta e refaz a etapa na mesma tentativa, sem
  gastar uma nova.
- Conecte quantas máquinas quiser: cada projeto diz em qual runner o código dele vive.

## O agente na máquina

O runner usa o `claude` instalado na máquina, com o login de quem o roda. A plataforma não
guarda a sua credencial do Claude. Quando a conta chega perto do limite de uso, o runner
mostra as barras de cada janela e o board avisa.
