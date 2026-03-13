#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

cleanup() {
    log "Shutting down..."
    [ -n "${P2POOL_PID:-}" ] && kill "$P2POOL_PID" 2>/dev/null || true
    [ -n "${MONEROD_PID:-}" ] && kill "$MONEROD_PID" 2>/dev/null || true
    [ -n "${TOR_PID:-}"     ] && kill "$TOR_PID"     2>/dev/null || true
    wait; exit 0
}
trap cleanup SIGTERM SIGINT

# ── validate required env ─────────────────────────────────────────────────────
: "${WALLET:?WALLET is required (set in setup.conf)}"
: "${P2POOL_MODE:?P2POOL_MODE is required: main | mini | nano}"
TOR_ENABLED="${TOR_ENABLED:-false}"
STRATUM_PORT=3333
MONEROD_ONION_PORT=18084   # localhost port monerod listens on for onion P2P

# ── optional Tor setup ────────────────────────────────────────────────────────
# Both a monerod hidden service (P2P) and a p2pool stratum hidden service are
# created when TOR_ENABLED=true.  Tor is started once and both HiddenService
# blocks are written to a single torrc before it starts.
TOR_PID=""
STRATUM_BIND="0.0.0.0:${STRATUM_PORT}"
MONEROD_ONION=""

if [ "$TOR_ENABLED" = "true" ]; then
    log "Configuring Tor hidden services (monerod RPC+P2P + p2pool stratum)..."

    # ── monerod hidden service (RPC 18089 + P2P inbound 18084) ───────────────
    # One HiddenServiceDir with two ports so both share the same .onion address.
    # 18089 lets you point your own wallet at the node over Tor.
    # 18084 is the anonymous-inbound P2P port monerod listens on locally.
    MONEROD_HS_DIR="/var/lib/tor/monerod"
    mkdir -p "$MONEROD_HS_DIR"
    chown debian-tor:debian-tor "$MONEROD_HS_DIR"
    chmod 700 "$MONEROD_HS_DIR"

    # ── p2pool stratum hidden service ─────────────────────────────────────────
    STRATUM_HS_DIR="/var/lib/tor/p2pool-stratum"
    mkdir -p "$STRATUM_HS_DIR"
    chown debian-tor:debian-tor "$STRATUM_HS_DIR"
    chmod 700 "$STRATUM_HS_DIR"

    # ── write torrc ───────────────────────────────────────────────────────────
    TORRC=/etc/tor/torrc-p2pool
    cat > "$TORRC" <<EOF
User debian-tor
SocksPort 9050
Log warn stderr
DataDirectory /var/lib/tor

# monerod hidden service — RPC (18089) + P2P inbound (18084)
HiddenServiceDir ${MONEROD_HS_DIR}
HiddenServicePort 18089 127.0.0.1:18089
HiddenServicePort 18084 127.0.0.1:${MONEROD_ONION_PORT}

# p2pool stratum hidden service
HiddenServiceDir ${STRATUM_HS_DIR}
HiddenServicePort ${STRATUM_PORT} 127.0.0.1:${STRATUM_PORT}
EOF
    # torrc must be owned by root or the tor user, and not group/world-writable
    chmod 644 "$TORRC"
    # /var/lib/tor DataDirectory must be owned by debian-tor
    chown debian-tor:debian-tor /var/lib/tor

    log "Starting Tor..."
    tor -f "$TORRC" &
    TOR_PID=$!

    log "Waiting for onion addresses..."
    until [ -f "$MONEROD_HS_DIR/hostname" ] && [ -f "$STRATUM_HS_DIR/hostname" ]; do
        sleep 2
    done

    MONEROD_ONION=$(tr -d '[:space:]' < "$MONEROD_HS_DIR/hostname")
    STRATUM_ONION=$(tr -d '[:space:]' < "$STRATUM_HS_DIR/hostname")
    log "monerod onion (RPC :18089, P2P :18084) : ${MONEROD_ONION}"
    log "p2pool stratum onion                   : ${STRATUM_ONION}:${STRATUM_PORT}"

    # ── patch monerod.conf with Tor lines (idempotent) ────────────────────────
    CONF=/etc/monero/monerod.conf
    # Ensure file ends with a newline before appending
    [ -s "$CONF" ] && [ "$(tail -c1 "$CONF" | wc -l)" -eq 0 ] && echo "" >> "$CONF"
    if ! grep -q "^anonymous-inbound=" "$CONF"; then
        echo "anonymous-inbound=${MONEROD_ONION}:18084,127.0.0.1:${MONEROD_ONION_PORT}" >> "$CONF"
    fi
    if ! grep -q "^tx-proxy=" "$CONF"; then
        echo "tx-proxy=tor,127.0.0.1:9050,disable_noise" >> "$CONF"
    fi

    # bind p2pool stratum to localhost only — access is via Tor hidden service
    STRATUM_BIND="127.0.0.1:${STRATUM_PORT}"
fi

# ── start monerod ─────────────────────────────────────────────────────────────
log "Starting monerod..."
su -s /bin/sh monerod -c \
    "monerod --config-file /etc/monero/monerod.conf --non-interactive" &
MONEROD_PID=$!

log "Waiting for monerod RPC on :18089..."
until curl -sf http://127.0.0.1:18089/get_height >/dev/null 2>&1; do sleep 3; done
log "monerod RPC is up."

# ── resolve p2pool mode flag ──────────────────────────────────────────────────
case "$P2POOL_MODE" in
    main) MODE_FLAG="" ;;
    mini) MODE_FLAG="--mini" ;;
    nano) MODE_FLAG="--nano" ;;
    *)    log "Unknown P2POOL_MODE '$P2POOL_MODE'. Use: main | mini | nano"; exit 1 ;;
esac

# ── start p2pool ──────────────────────────────────────────────────────────────
log "Starting p2pool (mode: $P2POOL_MODE, tor: $TOR_ENABLED)..."
su -s /bin/sh p2pool -c \
    "p2pool \
        --host 127.0.0.1 \
        --rpc-port 18089 \
        --zmq-port 18083 \
        --wallet ${WALLET} \
        --stratum ${STRATUM_BIND} \
        --data-dir /var/lib/p2pool \
        --log-file /var/log/p2pool/p2pool.log \
        ${MODE_FLAG}" &
P2POOL_PID=$!

log "All services running. monerod=$MONEROD_PID p2pool=$P2POOL_PID${TOR_PID:+ tor=$TOR_PID}"
if [ "$TOR_ENABLED" = "true" ]; then
    log "  monerod onion  RPC  : ${MONEROD_ONION}:18089"
    log "  monerod onion  P2P  : ${MONEROD_ONION}:18084"
    log "  p2pool stratum onion: ${STRATUM_ONION}:${STRATUM_PORT}"
fi

wait -n "$MONEROD_PID" "$P2POOL_PID" ${TOR_PID:-}
log "A process exited unexpectedly. Shutting down..."
cleanup
