# VPN Gateway Unificado — Podman

Imagem única com **openfortivpn** (autenticado por um daemon Python que
resolve SAML + MFA da Microsoft via Playwright/Chromium headless),
**snx-rs** (Check Point) e **WireGuard**, rodando túneis simultâneos, cada
um roteando apenas as sub-redes do cliente correspondente.

## Estrutura esperada do projeto

```
vpn-gateway/
├── Dockerfile
├── entrypoint.sh
├── scripts/
│   ├── start-forti-daemon.sh
│   ├── start-snx.sh
│   ├── start-wireguard.sh
│   └── healthcheck.sh
├── vpn-daemon/              <- você clona aqui ANTES do build (não versionado)
│   ├── vpn_daemon.py
│   └── requirements.txt
└── config-examples/
```

## Pré-requisitos no host (Oracle E1 / Ampere)

```bash
sudo apt-get update && sudo apt-get install -y podman git

sudo modprobe tun
ls -la /dev/net/tun   # deve existir
```

## 1. Clonar o daemon (fora do container)

O código do daemon fica num repo privado com deploy key. Clone ele **no
host**, direto na pasta `vpn-daemon/` ao lado do Dockerfile — assim a
chave nunca entra em nenhuma camada da imagem:

```bash
cd vpn-gateway
GIT_SSH_COMMAND="ssh -i /caminho/da/sua/deploy_key -o IdentitiesOnly=yes" \
  git clone git@github.com:sua-org/vpn-daemon.git vpn-daemon
```

`vpn-daemon/` já está no `.gitignore` deste projeto — o Dockerfile só faz
`COPY vpn-daemon/` do que estiver nessa pasta no momento do build.

## 2. Build da imagem

```bash
podman build -t vpn-gateway:latest .
```

O build:
- compila o `snx-rs` do source (stage 1, Rust)
- instala `openfortivpn`, `wireguard-tools` e as libs do Chromium headless
- cria o venv Python, instala `requirements.txt` e baixa o Chromium via
  `playwright install chromium`
- cria o usuário não-root `vpndaemon`, com `sudo NOPASSWD` restrito
  **apenas** ao binário `openfortivpn` (não a comandos arbitrários)

> **x86_64 agora, ARM64 depois:** para buildar explicitamente pra ARM
> quando migrar pra Ampere:
> ```bash
> podman build --platform linux/arm64 -t vpn-gateway:arm64 .
> ```
> O Chromium do Playwright tem build ARM64 oficial, então isso deve
> funcionar sem mudanças — mas vale testar o fluxo de MFA de novo depois
> da migração, containers ARM à vezes têm diferenças sutis de timing.

## 3. Preparar as configs

### Daemon SAML (openfortivpn)

Copie o exemplo de env e preencha com as credenciais reais:

```bash
cp config-examples/forti-daemon.env.example ~/vpn-configs/vpn-daemon.env
chmod 600 ~/vpn-configs/vpn-daemon.env
# edite VPN_GATEWAY, VPN_USERNAME, VPN_PASSWORD
```

**Nunca** passe essas credenciais via `ARG`/`ENV` no Dockerfile ou
`COPY` de um `.env` pra dentro da imagem — sempre via `--env-file` no
`podman run`, como no passo 4.

### snx-rs e WireGuard

```bash
mkdir -p ~/vpn-configs/{snx,wireguard}
cp config-examples/snx-config.example.toml ~/vpn-configs/snx/config.toml
cp config-examples/wg0.conf.example ~/vpn-configs/wireguard/wg0.conf
chmod 600 ~/vpn-configs/wireguard/wg0.conf
# edite com os dados reais de cada cliente
```

## 3.1 Port-forwards com socat (opcional)

A imagem inclui `socat`. Se algum serviço do lado do cliente precisa ser
exposto numa porta fixa do host (ex: RDP, um banco), em vez de subir
`socat` manualmente (o que não sobrevive a um restart do container), use
a env var `SOCAT_FORWARDS` — o `entrypoint.sh` recria os forwards toda
vez que o container inicia:

```bash
# formato: porta_local:ip_destino:porta_destino, separados por vírgula
SOCAT_FORWARDS="4000:10.105.0.2:3389,4001:10.105.0.2:19990,4002:10.105.0.2:18766"
```

Adicione ao `vpn-daemon.env` (ou passe com `-e`) e mapeie as portas
correspondentes no `podman run` com `-p`:

```bash
-e SOCAT_FORWARDS="4000:10.105.0.2:3389,4001:10.105.0.2:19990,4002:10.105.0.2:18766" \
-p 4000:4000 -p 4001:4001 -p 4002:4002 \
```

Cada forward roda como processo monitorado igual às VPNs (é derrubado
no `cleanup` e reiniciado junto com o resto se o container reiniciar) e
loga em `/var/log/vpn-gateway/socat.log`.

## 4. Rodar o container

```bash
podman run -d \
  --name vpn-gateway \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --env-file ~/vpn-configs/vpn-daemon.env \
  -v ~/vpn-configs/snx:/etc/vpn-gateway/snx:Z \
  -v ~/vpn-configs/wireguard:/etc/vpn-gateway/wireguard:Z \
  -v vpn-daemon-state:/opt/vpn-daemon/.local:Z \
  -p 3389:3389 \
  -p 5432:5432 \
  --restart unless-stopped \
  vpn-gateway:latest
```

Pontos importantes:

- **`--cap-add NET_ADMIN` + `--device /dev/net/tun`**: obrigatórios, sem
  isso nenhuma das três VPNs sobe.
- **`--env-file`**: é assim que `VPN_GATEWAY`/`VPN_USERNAME`/`VPN_PASSWORD`
  chegam no daemon, sem tocar a imagem.
- **`vpn-daemon-state` (volume nomeado)**: persiste a sessão do navegador
  (`browser_state.json`) entre restarts do container. É esse volume que
  guarda o cookie "não perguntar novamente por 14 dias" do Azure AD — sem
  ele, todo restart do container = MFA de novo. Crie o volume antes, se
  quiser:
  ```bash
  podman volume create vpn-daemon-state
  ```
- Ajuste as portas `-p` para os serviços reais atrás de cada túnel (RDP,
  bancos, etc.) — como cada VPN roteia só a sub-rede do seu cliente, o
  container atua como gateway único.

## 5. Primeira execução (MFA)

Como `VPN_HEADLESS=1` é o padrão, o Chromium roda sem janela — a
aprovação do MFA acontece no **celular do usuário titular da conta**, não
no terminal. Acompanhe pelos logs:

```bash
podman logs -f vpn-gateway
# ou especificamente:
podman exec vpn-gateway tail -f /var/log/vpn-gateway/forti.log
```

Você vai ver o número de number-matching no log (`🔢 Número para
confirmar no celular: XX`) — confirme esse número no app Microsoft
Authenticator. Depois da primeira aprovação bem-sucedida, a sessão fica
salva no volume `vpn-daemon-state` e as próximas reconexões (dentro da
janela de 14 dias do "não perguntar novamente") não devem pedir MFA de
novo.

Se precisar depurar visualmente o fluxo (ex: seletor quebrou depois de
uma atualização do Azure AD), rode uma vez com:

```bash
podman run --rm -it \
  --cap-add NET_ADMIN --device /dev/net/tun \
  --env-file ~/vpn-configs/vpn-daemon.env \
  -e VPN_SCREENSHOTS=1 -e VPN_DEBUG=1 \
  -v vpn-daemon-state:/opt/vpn-daemon/.local:Z \
  vpn-gateway:latest
```

E depois inspecione as screenshots em
`/opt/vpn-daemon/.local/share/vpn-daemon/screenshots/` dentro do
container (`podman cp` pra tirar do container).

## 6. Verificar que os túneis subiram

```bash
podman exec vpn-gateway ip -brief addr show
# Deve mostrar ppp0 (forti), tun0/snx0 (snx-rs) e wg0 (wireguard)

podman exec vpn-gateway ip route show
```

## 7. Logs

```bash
podman exec vpn-gateway tail -f /var/log/vpn-gateway/forti.log
podman exec vpn-gateway tail -f /var/log/vpn-gateway/snx.log
podman exec vpn-gateway tail -f /var/log/vpn-gateway/wireguard.log
```

## Sobre o roteamento simultâneo

Como cada VPN aqui é configurada para **não** assumir a rota default
(`no-default-route`/`AllowedIPs` restrito às sub-redes do cliente), as
três interfaces coexistem sem conflito de rota. O tráfego para a sub-rede
do Cliente A vai por `ppp0`, do Cliente B por `snx0`/`tun0`, do Cliente C
por `wg0`, e todo o resto sai pela rota default normal do container.

Se algum cliente exigir que TODO o tráfego passe pelo túnel dele
(0.0.0.0/0), isso vai conflitar com os outros dois — nesse caso, vocês
precisam de policy routing (tabelas de rota separadas + `ip rule`) em vez
de rota simples.

## Segurança

- `vpn-daemon.env` e as pastas de config têm credenciais e chaves
  privadas — nunca commitar, sempre `chmod 600`.
- O daemon roda como usuário não-root (`vpndaemon`) com `sudo NOPASSWD`
  restrito **apenas** ao binário `openfortivpn` — não há acesso root
  irrestrito no container.
- O container ainda precisa de `NET_ADMIN`, que é um privilégio elevado
  no nível do container — trate o host Oracle como perímetro de
  confiança.
- Considere rodar o container em rede isolada (`podman network create`)
  e só expor as portas de serviço (RDP, DB) que realmente precisam ser
  acessadas externamente.
- O volume `vpn-daemon-state` guarda sessão de autenticação — trate-o com
  o mesmo cuidado que uma credencial (backup criptografado, acesso
  restrito ao host).
