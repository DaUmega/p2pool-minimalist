#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

cleanup() {
    log "Shutting down..."
    [ -n "${P2POOL_PID:-}" ]       && kill "$P2POOL_PID"       2>/dev/null || true
    [ -n "${MONEROD_PID:-}" ]      && kill "$MONEROD_PID"      2>/dev/null || true
    [ -n "${TOR_PID:-}" ]          && kill "$TOR_PID"          2>/dev/null || true
    [ -n "${HEALTH_CHECK_PID:-}" ] && kill "$HEALTH_CHECK_PID" 2>/dev/null || true
    [ -n "${LOGROTATE_PID:-}" ]    && kill "$LOGROTATE_PID"    2>/dev/null || true
    wait; exit 0
}
trap cleanup SIGTERM SIGINT

# ── validate required env ─────────────────────────────────────────────────────
: "${WALLET:?WALLET is required (set in setup.conf)}"
: "${P2POOL_MODE:?P2POOL_MODE is required: main | mini | nano}"
TOR_ENABLED="${TOR_ENABLED:-false}"
STRATUM_PORT=3333
MONEROD_ONION_PORT=18084

# ── Tari merge mining ─────────────────────────────────────────────────────────
# TARI_WALLET and TARI_NODE_HOST are optional; merge mining is skipped if unset.
TARI_WALLET="${TARI_WALLET:-}"
TARI_NODE_HOST="${TARI_NODE_HOST:-}"
TARI_GRPC_PORT="${TARI_GRPC_PORT:-18142}"
MERGE_MINE_FLAG=""
if [ -n "$TARI_WALLET" ] && [ -n "$TARI_NODE_HOST" ]; then
    log "Tari merge mining enabled → tari://${TARI_NODE_HOST}:${TARI_GRPC_PORT}"
    MERGE_MINE_FLAG="--merge-mine tari://${TARI_NODE_HOST}:${TARI_GRPC_PORT} ${TARI_WALLET}"
else
    log "Tari merge mining disabled (TARI_WALLET or TARI_NODE_HOST not set)"
fi

TOR_PID=""
LOGROTATE_PID=""
STRATUM_BIND="0.0.0.0:${STRATUM_PORT}"
MONEROD_ONION=""
HEALTH_CHECK_PID=""
TARI_INITIALLY_READY=false

if [ "$TOR_ENABLED" = "true" ]; then
    log "Configuring Tor hidden services (monerod RPC+P2P + p2pool stratum)..."

    MONEROD_HS_DIR="/var/lib/tor/monerod"
    mkdir -p "$MONEROD_HS_DIR"
    chown debian-tor:debian-tor "$MONEROD_HS_DIR"
    chmod 700 "$MONEROD_HS_DIR"

    STRATUM_HS_DIR="/var/lib/tor/p2pool-stratum"
    mkdir -p "$STRATUM_HS_DIR"
    chown debian-tor:debian-tor "$STRATUM_HS_DIR"
    chmod 700 "$STRATUM_HS_DIR"

    TORRC=/etc/tor/torrc-p2pool
    cat > "$TORRC" <<EOF
User debian-tor
SocksPort 9050
Log warn stderr
DataDirectory /var/lib/tor

HiddenServiceDir ${MONEROD_HS_DIR}
HiddenServicePort 18089 127.0.0.1:18089
HiddenServicePort 18084 127.0.0.1:${MONEROD_ONION_PORT}

HiddenServiceDir ${STRATUM_HS_DIR}
HiddenServicePort ${STRATUM_PORT} 127.0.0.1:${STRATUM_PORT}
EOF
    chmod 644 "$TORRC"
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

    CONF=/etc/monero/monerod.conf
    [ -s "$CONF" ] && [ "$(tail -c1 "$CONF" | wc -l)" -eq 0 ] && echo "" >> "$CONF"
    if ! grep -q "^anonymous-inbound=" "$CONF"; then
        echo "anonymous-inbound=${MONEROD_ONION}:18084,127.0.0.1:${MONEROD_ONION_PORT}" >> "$CONF"
    fi
    if ! grep -q "^tx-proxy=" "$CONF"; then
        echo "tx-proxy=tor,127.0.0.1:9050,disable_noise" >> "$CONF"
    fi

    STRATUM_BIND="127.0.0.1:${STRATUM_PORT}"
fi

# ── monerod pruning ───────────────────────────────────────────────────────────
MONERO_PRUNED="${MONERO_PRUNED:-true}"
if [ "$MONERO_PRUNED" != "true" ]; then
    log "Full archival node mode — removing pruning flags from monerod.conf"
    sed -i '/^prune-blockchain=/d; /^sync-pruned-blocks=/d' /etc/monero/monerod.conf
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

# ── initial wait for Tari node gRPC (if merge mining intended) ────────────────
TARI_INITIALLY_READY=false
if [ -n "$MERGE_MINE_FLAG" ]; then
    log "Waiting for Tari node gRPC on ${TARI_NODE_HOST}:${TARI_GRPC_PORT} (initial timeout 60s)..."
    WAIT=0
    until nc -z "${TARI_NODE_HOST}" "${TARI_GRPC_PORT}" 2>/dev/null; do
        sleep 5
        WAIT=$((WAIT+5))
        if [ "$WAIT" -ge 60 ]; then
            log "INFO: Tari node not reachable after 60s — starting p2pool in regular mode"
            log "      • Merge mining will be auto-enabled once Tari becomes ready"
            MERGE_MINE_FLAG=""
            break
        fi
    done
    if [ -n "$MERGE_MINE_FLAG" ]; then
        log "Tari node gRPC is reachable — merge mining enabled at startup."
        TARI_INITIALLY_READY=true
    fi
fi

# ── start p2pool ──────────────────────────────────────────────────────────────
log "Starting p2pool (mode: $P2POOL_MODE, tor: $TOR_ENABLED, tari: ${MERGE_MINE_FLAG:+yes}${MERGE_MINE_FLAG:-no})..."
su -s /bin/sh p2pool -c \
    "p2pool \
        --host 127.0.0.1 \
        --rpc-port 18089 \
        --zmq-port 18083 \
        --wallet ${WALLET} \
        --stratum ${STRATUM_BIND} \
        --data-dir /var/lib/p2pool \
        --log-file /var/log/p2pool/p2pool.log \
        ${MODE_FLAG} \
        ${MERGE_MINE_FLAG}" &
P2POOL_PID=$!

log "All services running. monerod=$MONEROD_PID p2pool=$P2POOL_PID${TOR_PID:+ tor=$TOR_PID}"
if [ -n "$MERGE_MINE_FLAG" ]; then
    log "  Tari merge mining → tari://${TARI_NODE_HOST}:${TARI_GRPC_PORT}"
fi
if [ "$TOR_ENABLED" = "true" ]; then
    log "  monerod onion  RPC  : ${MONEROD_ONION}:18089"
    log "  monerod onion  P2P  : ${MONEROD_ONION}:18084"
    log "  p2pool stratum onion: ${STRATUM_ONION}:${STRATUM_PORT}"
fi

# ── background health check: bidirectional merge mining mode switching ─────────
if [ -n "$TARI_WALLET" ] && [ -n "$TARI_NODE_HOST" ]; then
    log "Starting background Tari health monitor (bidirectional mode switching)..."
    (
        MERGE_MINING_ACTIVE=false
        if [ "$TARI_INITIALLY_READY" = "true" ]; then
            MERGE_MINING_ACTIVE=true
        fi

        CONSECUTIVE_FAILURES=0
        CONSECUTIVE_SUCCESSES=0

        while true; do
            sleep 30

            if nc -z "${TARI_NODE_HOST}" "${TARI_GRPC_PORT}" 2>/dev/null; then
                CONSECUTIVE_FAILURES=0
                CONSECUTIVE_SUCCESSES=$((CONSECUTIVE_SUCCESSES+1))

                if [ "$MERGE_MINING_ACTIVE" = "false" ] && [ "$CONSECUTIVE_SUCCESSES" -ge 2 ]; then
                    log "[health] Tari node online (${CONSECUTIVE_SUCCESSES}x checks). Enabling merge mining..."
                    kill "$P2POOL_PID" 2>/dev/null || true
                    wait "$P2POOL_PID" 2>/dev/null || true

                    su -s /bin/sh p2pool -c \
                        "p2pool \
                            --host 127.0.0.1 \
                            --rpc-port 18089 \
                            --zmq-port 18083 \
                            --wallet ${WALLET} \
                            --stratum ${STRATUM_BIND} \
                            --data-dir /var/lib/p2pool \
                            --log-file /var/log/p2pool/p2pool.log \
                            ${MODE_FLAG} \
                            --merge-mine tari://${TARI_NODE_HOST}:${TARI_GRPC_PORT} ${TARI_WALLET}" &
                    P2POOL_PID=$!
                    MERGE_MINING_ACTIVE=true
                    CONSECUTIVE_SUCCESSES=0
                    log "[health] p2pool (PID=$P2POOL_PID) restarted with merge mining enabled"
                fi
            else
                CONSECUTIVE_SUCCESSES=0
                CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES+1))

                if [ "$MERGE_MINING_ACTIVE" = "true" ] && [ "$CONSECUTIVE_FAILURES" -ge 2 ]; then
                    log "[health] Tari node offline (${CONSECUTIVE_FAILURES}x failures). Reverting to Monero-only mode..."
                    kill "$P2POOL_PID" 2>/dev/null || true
                    wait "$P2POOL_PID" 2>/dev/null || true

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
                    MERGE_MINING_ACTIVE=false
                    CONSECUTIVE_FAILURES=0
                    log "[health] p2pool (PID=$P2POOL_PID) restarted in Monero-only mode"
                fi
            fi
        done
    ) &
    HEALTH_CHECK_PID=$!
fi

# ── log rotation ──────────────────────────────────────────────────────────────
LOG_MAX_SIZE="${LOG_MAX_SIZE:-500M}"
if [ "$LOG_MAX_SIZE" != "0" ]; then
    cat > /etc/logrotate.d/mining <<EOF
/var/log/p2pool/p2pool.log /var/log/monero/*.log {
    size ${LOG_MAX_SIZE}
    rotate 1
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    (while true; do sleep 300; logrotate /etc/logrotate.d/mining 2>/dev/null || true; done) &
    LOGROTATE_PID=$!
    log "Log rotation enabled (max size: ${LOG_MAX_SIZE})"
fi

wait -n "$MONEROD_PID" "$P2POOL_PID" ${TOR_PID:-}
log "A process exited unexpectedly. Shutting down..."
cleanup
