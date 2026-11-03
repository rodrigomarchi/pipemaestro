# Protocolo runner ↔ control plane (v1)

> Status: v1, implementada em `apps/claude_control_plane_protocol` (fonte da
> verdade das constantes e do formato do `Hello`). Esta fase cobre login e
> conexão; jobs, leases e eventos de execução entram em versões seguintes.

## Princípios

- **A conexão parte sempre do runner.** O cliente não abre nenhuma porta de entrada.
- **O runner tem identidade própria.** Ele recebe um token próprio e nunca guarda a
  credencial de uma pessoa. O control plane armazena só o SHA-256 desse token.
- **A versão é declarada em toda conexão.** O control plane aceita as versões de
  `ClaudeControlPlaneProtocol.supported_versions/0`.

## 1. Login (device flow)

Segue o modelo do OAuth 2.0 Device Authorization Grant (RFC 8628).

### 1.1 Pedir um código

`POST /api/runner/device/code`

```json
{
  "hello": {
    "protocol_version": 1, "runner_version": "0.1.0",
    "hostname": "build-01", "os": "linux", "arch": "x86_64",
    "labels": ["linux", "docker"], "capacity": 4
  },
  "name": "Servidor de build"
}
```

`name` é opcional; o padrão é o hostname. A resposta é `200`:

```json
{
  "device_code": "<segredo, só o runner conhece>",
  "user_code": "WDJB-MJHT",
  "verification_uri": "https://plataforma/runners/activate",
  "verification_uri_complete": "https://plataforma/runners/activate?code=WDJB-MJHT",
  "expires_in": 600,
  "interval": 5
}
```

O `user_code` tem 8 consoantes (sem vogais e sem caracteres ambíguos); maiúsculas,
espaços e hífen não importam na digitação.

### 1.2 Aprovação

A pessoa abre `verification_uri` já logada, confere o pedido (hostname, SO, labels e
capacidade), escolhe um workspace do qual é membro e o nome do runner, e então
**aprova** ou **recusa**.

### 1.3 Polling

`POST /api/runner/device/token` com `{"device_code": "..."}`, a cada `interval` segundos.

| Resposta | Significado | O que o runner faz |
|---|---|---|
| `200` `{runner_token, runner: {id, name}, workspace: {name, slug}}` | aprovado | grava as credenciais e termina |
| `400` `{"error": "authorization_pending"}` | ainda não aprovado | espera `interval` e tenta de novo |
| `400` `{"error": "slow_down"}` | consultou rápido demais | soma 5 s ao intervalo |
| `400` `{"error": "access_denied"}` | recusado | encerra |
| `400` `{"error": "expired_token"}` | o código expirou | encerra |
| `400` `{"error": "invalid_request"}` | código desconhecido ou já usado | encerra |

O token (`cpr_…`) é emitido uma única vez, na primeira consulta depois da aprovação.

## 2. Conexão

O runner abre um WebSocket Phoenix (serializador v2) em
`ws(s)://<plataforma>/runner/socket/websocket?token=<runner_token>&protocol_version=1`.

Token inválido, runner revogado ou versão não suportada fazem a plataforma recusar
o upgrade com **HTTP 403**. Uma nova tentativa não resolve: o runner encerra e
orienta a pessoa a fazer o login de novo. Para qualquer outra queda, o runner
reconecta com backoff (0,5 s, 1 s, 2 s, 5 s, 10 s e depois 30 s).

## 3. Canal `runner:<runner_id>`

- **Join:** o payload é o `Hello` (o mesmo formato da seção 1.1). A resposta é
  `{"runner_id", "name", "workspace"}`. Entrar no tópico de outro runner dá
  `{"reason": "unauthorized"}`, e um `Hello` inválido dá `{"reason": "invalid_hello"}`.
- **O que acontece no join:** o control plane grava o `Hello` (labels, capacidade,
  versão, hostname, SO e arch) e passa a mostrar o runner como **online** no
  workspace enquanto o canal existir.
- **Heartbeat:** é o do Phoenix. O cliente envia um a cada 30 s, e o servidor
  derruba a conexão depois de 60 s sem receber nenhum.
- **Revogação:** o control plane manda `disconnect` para o socket
  `runner_socket:<id>`. A reconexão que vem em seguida recebe 403.

## 4. Versionamento

`protocol_version` aumenta quando muda algo que quebra compatibilidade. O control
plane mantém as versões anteriores em `supported_versions/0` durante a janela de
compatibilidade, e o runner sempre anuncia a versão com que foi compilado.
