#!/bin/bash
set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [forti-daemon] $*"
}

# Variáveis obrigatórias do daemon Python: VPN_GATEWAY, VPN_USERNAME,
# VPN_PASSWORD. Elas devem chegar via -e/--env-file no `podman run`,
# nunca via Dockerfile/imagem.
: "${VPN_GATEWAY:?VPN_GATEWAY não definida — passe via -e ou --env-file no podman run}"
: "${VPN_USERNAME:?VPN_USERNAME não definida — passe via -e ou --env-file no podman run}"
: "${VPN_PASSWORD:?VPN_PASSWORD não definida — passe via -e ou --env-file no podman run}"

export VPN_HEADLESS="${VPN_HEADLESS:-1}"
export VPN_DEBUG="${VPN_DEBUG:-0}"
export VPN_SCREENSHOTS="${VPN_SCREENSHOTS:-0}"

log "Subindo daemon Python (openfortivpn/SAML) como usuário vpndaemon..."

# O daemon já cuida de: iniciar o openfortivpn via sudo (NOPASSWD
# configurado no Dockerfile só pra esse binário), abrir o Chromium
# headless, resolver o fluxo SAML/MFA, e manter a interface ppp0 viva
# com seu próprio loop de retry — não precisamos supervisionar nada
# além de repassar sinais e deixar o processo em foreground.
exec gosu vpndaemon /opt/vpn-daemon/.venv/bin/python /opt/vpn-daemon/vpn_daemon.py
