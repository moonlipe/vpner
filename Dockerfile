# syntax=docker/dockerfile:1.7

# =========================================================
# Stage 1 - build snx-rs a partir do source (Rust)
# =========================================================
# snx-rs usa Cargo edition2024, estabilizada só a partir do Rust 1.85 —
# 1.80 dava "feature `edition2024` is required". Usamos "rust:slim-bookworm"
# (sem pin de versão) pra sempre pegar o Rust estável mais recente e não
# repetir esse problema quando o snx-rs adotar features futuras.
FROM rust:slim-bookworm AS snx-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pkg-config \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Repo oficial do snx-rs (ajuste a tag/branch se quiser fixar uma versão)
RUN git clone --depth 1 https://github.com/ancwrd1/snx-rs.git .

RUN cargo build --release --bin snx-rs && \
    cargo build --release --bin snxctl

# =========================================================
# Stage 2 - imagem final
# =========================================================
FROM debian:bookworm-slim

LABEL maintainer="infra@suaempresa.com"
LABEL description="Gateway VPN unificado: openfortivpn (daemon SAML/Playwright) + snx-rs + WireGuard"

ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# Pacotes base + openfortivpn + wireguard + libs headless do Chromium
# (equivalente Debian/apt da lista dnf do setup.sh original, que era
# pra Oracle Linux/RHEL — os nomes de pacote mudam mas a cobertura é a
# mesma exigida pelo `playwright install-deps`)
# ------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    openfortivpn \
    wireguard-tools \
    iproute2 \
    iptables \
    iputils-ping \
    dnsutils \
    curl \
    ca-certificates \
    openssl \
    bash \
    procps \
    net-tools \
    sudo \
    gosu \
    python3 \
    python3-venv \
    python3-pip \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libgbm1 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libxshmfence1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# Binários do snx-rs vindos do stage de build
COPY --from=snx-builder /build/target/release/snx-rs /usr/local/bin/snx-rs
COPY --from=snx-builder /build/target/release/snxctl /usr/local/bin/snxctl
RUN chmod +x /usr/local/bin/snx-rs /usr/local/bin/snxctl

# ------------------------------------------------------------
# Usuário não-root pro daemon, com sudo NOPASSWD restrito só ao
# openfortivpn (nada de rodar o container inteiro como root)
# ------------------------------------------------------------
# ------------------------------------------------------------
# Usuário não-root pro daemon, com sudo NOPASSWD restrito só ao
# openfortivpn e pkill (nada de rodar o container inteiro como root)
#
# O caminho do binário openfortivpn varia entre versões/distros do
# pacote apt (pode ser /usr/sbin/ ou /usr/bin/) — resolvemos com `which`
# no momento do build em vez de fixar um caminho que pode não bater com
# o real, o que faria o sudo recusar silenciosamente (regra não confere
# com o caminho exato chamado) e travar esperando senha.
# ------------------------------------------------------------
RUN useradd --system --create-home --home-dir /opt/vpn-daemon --shell /bin/bash vpndaemon && \
    OPENFORTIVPN_BIN="$(command -v openfortivpn)" && \
    PKILL_BIN="$(command -v pkill)" && \
    echo "vpndaemon ALL=(root) NOPASSWD: ${OPENFORTIVPN_BIN}, ${PKILL_BIN}" \
        > /etc/sudoers.d/vpndaemon && \
    chmod 440 /etc/sudoers.d/vpndaemon && \
    visudo -c && \
    echo "openfortivpn resolvido em: ${OPENFORTIVPN_BIN}" && \
    echo "pkill resolvido em: ${PKILL_BIN}"

# Estrutura de diretórios de config (serão montados como volumes em produção)
RUN mkdir -p \
    /etc/vpn-gateway/snx \
    /etc/vpn-gateway/wireguard \
    /var/log/vpn-gateway \
    /opt/vpn-daemon

# ------------------------------------------------------------
# Daemon Python (openfortivpn/SAML) — código já clonado no host
# via chave de deploy, copiado do build context em vpn-daemon/
# ------------------------------------------------------------
COPY vpn-daemon/requirements.txt /opt/vpn-daemon/requirements.txt
RUN python3 -m venv /opt/vpn-daemon/.venv && \
    /opt/vpn-daemon/.venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/vpn-daemon/.venv/bin/pip install --no-cache-dir -r /opt/vpn-daemon/requirements.txt && \
    /opt/vpn-daemon/.venv/bin/python -m playwright install chromium && \
    chown -R vpndaemon:vpndaemon /opt/vpn-daemon

COPY vpn-daemon/ /opt/vpn-daemon/
RUN chown -R vpndaemon:vpndaemon /opt/vpn-daemon

# Scripts de controle (snx, wireguard, entrypoint, healthcheck)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/start-snx.sh /usr/local/bin/start-snx.sh
COPY scripts/start-wireguard.sh /usr/local/bin/start-wireguard.sh
COPY scripts/start-forti-daemon.sh /usr/local/bin/start-forti-daemon.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/start-snx.sh \
    /usr/local/bin/start-wireguard.sh \
    /usr/local/bin/start-forti-daemon.sh \
    /usr/local/bin/healthcheck.sh

# WireGuard precisa do módulo/dev tun; expõe a porta padrão caso o container
# também sirva de peer (ajuste conforme seu uso real)
EXPOSE 51820/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]