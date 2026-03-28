#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

cleanup() {
    log "Shutting down..."
    pkill -TERM monerod      2>/dev/null || true
    pkill -TERM p2pool       2>/dev/null || true
    pkill -TERM minotari_node 2>/dev/null || true
    pkill -TERM tor          2>/dev/null || true
    wait
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── validate required env ─────────────────────────────────────────────────────
: "${WALLET:?WALLET is required}"
: "${P2POOL_MODE:?P2POOL_MODE is required: main | mini | nano}"

TOR_ENABLED="${TOR_ENABLED:-false}"
TARI_WALLET="${TARI_WALLET:-}"

STRATUM_PORT=3333
STRATUM_BIND="0.0.0.0:${STRATUM_PORT}"
MONEROD_ONION_PORT=18084

# ── p2pool mode flag ──────────────────────────────────────────────────────────
case "$P2POOL_MODE" in
    main) MODE_FLAG="" ;;
    mini) MODE_FLAG="--mini" ;;
    nano) MODE_FLAG="--nano" ;;
    *)    log "Invalid P2POOL_MODE: $P2POOL_MODE"; exit 1 ;;
esac

# ── tari setup ────────────────────────────────────────────────────────────────
if [ -n "$TARI_WALLET" ]; then
    mkdir -p /var/lib/tari
    chown -R tari:tari /var/lib/tari
    log "Tari merge mining enabled"
else
    log "Tari merge mining disabled"
fi

# ── tor setup ─────────────────────────────────────────────────────────────────
if [ "$TOR_ENABLED" = "true" ]; then
    log "Configuring Tor..."

    MONEROD_HS_DIR="/var/lib/tor/monerod"
    STRATUM_HS_DIR="/var/lib/tor/p2pool-stratum"

    mkdir -p "$MONEROD_HS_DIR" "$STRATUM_HS_DIR"
    chown -R debian-tor:debian-tor /var/lib/tor
    chmod 700 "$MONEROD_HS_DIR" "$STRATUM_HS_DIR"

    cat > /etc/tor/torrc-p2pool <<EOF
User debian-tor
DataDirectory /var/lib/tor
SocksPort 9050
ControlPort 9051
CookieAuthentication 1
CookieAuthFile /var/lib/tor/control_auth_cookie

HiddenServiceDir ${MONEROD_HS_DIR}
HiddenServicePort 18089 127.0.0.1:18089
HiddenServicePort 18084 127.0.0.1:${MONEROD_ONION_PORT}

HiddenServiceDir ${STRATUM_HS_DIR}
HiddenServicePort ${STRATUM_PORT} 127.0.0.1:${STRATUM_PORT}
EOF

    tor -f /etc/tor/torrc-p2pool &

    log "Waiting for onion services..."
    until [ -f "$MONEROD_HS_DIR/hostname" ]; do sleep 2; done

    STRATUM_BIND="127.0.0.1:${STRATUM_PORT}"
fi

# ── monerod ───────────────────────────────────────────────────────────────────
log "Starting monerod..."
su -s /bin/sh monerod -c \
    "monerod --config-file /etc/monero/monerod.conf --non-interactive" &

log "Waiting for monerod RPC..."
until curl -sf http://127.0.0.1:18089/get_height >/dev/null 2>&1; do sleep 3; done

# ── tmux server ───────────────────────────────────────────────────────────────
tmux start-server

# ── tari (interactive tmux) ───────────────────────────────────────────────────
if [ -n "$TARI_WALLET" ]; then
    log "Starting minotari_node watchdog (tmux: tari)..."
    tmux new-session -d -s tari \
        "while true; do
            echo '[tari] Starting minotari_node...'
            su -s /bin/sh tari -c '
                minotari_node \
                    --mining-enabled \
                    -p base_node.grpc_enabled=true \
                    -p base_node.grpc_address=/ip4/127.0.0.1/tcp/18142
            '
            echo '[tari] minotari_node exited (OOM or crash), restarting in 5s...'
            sleep 5
        done"
fi

# ── p2pool (interactive tmux) ─────────────────────────────────────────────────
log "Starting p2pool (tmux: p2pool)..."

MERGE_MINE_ARGS=""
[ -n "$TARI_WALLET" ] && MERGE_MINE_ARGS="--merge-mine tari://127.0.0.1:18142 ${TARI_WALLET}"

tmux new-session -d -s p2pool \
    "su -s /bin/sh p2pool -c '
        p2pool \
            --host 127.0.0.1 \
            --rpc-port 18089 \
            --zmq-port 18083 \
            --wallet ${WALLET} \
            --stratum ${STRATUM_BIND} \
            --data-dir /var/lib/p2pool \
            ${MODE_FLAG} \
            ${MERGE_MINE_ARGS}
    '"

# ── logrotate loop ────────────────────────────────────────────────────────────
while sleep 3600; do logrotate /etc/logrotate.conf; done &

# ── keep container alive ──────────────────────────────────────────────────────
wait
