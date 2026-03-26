#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

cleanup() {
    log "Shutting down..."
    [ -n "${P2POOL_PID:-}"    ] && kill "$P2POOL_PID"    2>/dev/null || true
    [ -n "${MONEROD_PID:-}"   ] && kill "$MONEROD_PID"   2>/dev/null || true
    [ -n "${TARI_PID:-}"      ] && kill "$TARI_PID"      2>/dev/null || true
    [ -n "${TOR_PID:-}"       ] && kill "$TOR_PID"       2>/dev/null || true
    [ -n "${LOGROTATE_PID:-}" ] && kill "$LOGROTATE_PID" 2>/dev/null || true
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
# TARI_WALLET is optional; merge mining is skipped if unset.
# Ports per official documentation:
#   18141 = Tari P2P (peer connectivity, per tari.com/integration-guide)
#   18142 = Tari gRPC exchange/wallet API (per tari.com/integration-guide)
#   18102 = Tari merge mining gRPC endpoint (per SChernykh/p2pool README)
TARI_WALLET="${TARI_WALLET:-}"
TARI_PRUNING_HORIZON="${TARI_PRUNING_HORIZON:-1000}"
TARI_MEMORY="${TARI_MEMORY:-3g}"
MERGE_MINE_FLAG=""
TARI_PID=""

TOR_PID=""
LOGROTATE_PID=""
STRATUM_BIND="0.0.0.0:${STRATUM_PORT}"
MONEROD_ONION=""

if [ -n "$TARI_WALLET" ]; then
    mkdir -p /var/lib/tari /var/log/tari
    chown -R tari:tari /var/lib/tari /var/log/tari
    log "tari directory ownership fixed."
fi

if [ -n "$TARI_WALLET" ]; then
    log "Tari merge mining enabled → grpc://127.0.0.1:18102"
    MERGE_MINE_FLAG="--merge-mine tari://127.0.0.1:18102 ${TARI_WALLET}"
else
    log "Tari merge mining disabled (TARI_WALLET not set)"
fi

if [ "$TOR_ENABLED" = "true" ]; then
    log "Configuring Tor hidden services (monerod RPC+P2P + p2pool stratum + tari P2P)..."

    MONEROD_HS_DIR="/var/lib/tor/monerod"
    mkdir -p "$MONEROD_HS_DIR"
    chown debian-tor:debian-tor "$MONEROD_HS_DIR"
    chmod 700 "$MONEROD_HS_DIR"

    STRATUM_HS_DIR="/var/lib/tor/p2pool-stratum"
    mkdir -p "$STRATUM_HS_DIR"
    chown debian-tor:debian-tor "$STRATUM_HS_DIR"
    chmod 700 "$STRATUM_HS_DIR"

    TARI_HS_DIR="/var/lib/tor/tari"
    mkdir -p "$TARI_HS_DIR"
    chown debian-tor:debian-tor "$TARI_HS_DIR"
    chmod 700 "$TARI_HS_DIR"

    TORRC=/etc/tor/torrc-p2pool
    cat > "$TORRC" <<EOF
User debian-tor
DataDirectory /var/lib/tor
# Allow the tari user (added to debian-tor group) to read the cookie file
# so minotari_node can authenticate to the control port without libtor.
DataDirectoryGroupReadable 1
CookieAuthFileGroupReadable 1
SocksPort 9050
ControlPort 9051
CookieAuthentication 1
CookieAuthFile /var/lib/tor/control_auth_cookie
Log warn stderr

HiddenServiceDir ${MONEROD_HS_DIR}
HiddenServicePort 18089 127.0.0.1:18089
HiddenServicePort 18084 127.0.0.1:${MONEROD_ONION_PORT}

HiddenServiceDir ${STRATUM_HS_DIR}
HiddenServicePort ${STRATUM_PORT} 127.0.0.1:${STRATUM_PORT}

HiddenServiceDir ${TARI_HS_DIR}
HiddenServicePort 18141 127.0.0.1:18141
EOF
    chmod 644 "$TORRC"
    chown debian-tor:debian-tor /var/lib/tor

    # Add tari user to debian-tor group so it can read the control auth cookie.
    if [ -n "$TARI_WALLET" ]; then
        usermod -aG debian-tor tari
        log "Added tari user to debian-tor group (cookie auth access)"
    fi

    log "Starting Tor..."
    tor -f "$TORRC" &
    TOR_PID=$!

    log "Waiting for onion addresses..."
    until [ -f "$MONEROD_HS_DIR/hostname" ] && [ -f "$STRATUM_HS_DIR/hostname" ] && [ -f "$TARI_HS_DIR/hostname" ]; do
        sleep 2
    done

    MONEROD_ONION=$(tr -d '[:space:]' < "$MONEROD_HS_DIR/hostname")
    STRATUM_ONION=$(tr -d '[:space:]' < "$STRATUM_HS_DIR/hostname")
    TARI_ONION=$(tr -d '[:space:]' < "$TARI_HS_DIR/hostname")
    log "monerod onion (RPC :18089, P2P :18084) : ${MONEROD_ONION}"
    log "p2pool stratum onion                   : ${STRATUM_ONION}:${STRATUM_PORT}"
    log "tari P2P onion                         : ${TARI_ONION}:18141"

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

# ── start minotari_node ───────────────────────────────────────────────────────
if [ -n "$TARI_WALLET" ]; then
    TARI_ID_FILE="/var/lib/tari/.tari/mainnet/config/base_node_id.json"
    if [ ! -f "$TARI_ID_FILE" ]; then
        log "No tari identity found — running first-time init (expect)..."
        # expect is installed in the Dockerfile; it answers both Y/n prompts
        # then sends Ctrl-C once the node is running to exit cleanly.
        su -s /bin/sh tari -c \
            'expect -c "
                log_user 1
                set timeout 120
                spawn minotari_node
                # Answer Y to every prompt until the node is running,
                # then Ctrl-C to exit the init run cleanly.
                expect {
                    -re {\(Y/n\)|\(y/N\)|\[Y/n\]|\[y/n\]} {
                        sleep 0.5
                        send \"Y\r\"
                        exp_continue
                    }
                    -re {grpc_address|Mempool|Listening on|WARN  Tor} {
                        send \"\003\"
                    }
                    eof     {}
                    timeout { send \"\003\" }
                }
                wait
            "' >> /var/log/tari/tari-node.log 2>&1 || true

        if [ ! -f "$TARI_ID_FILE" ]; then
            log "ERROR: tari identity file still missing after init. Check /var/log/tari/tari-node.log"
            exit 1
        fi
        log "Tari identity created: $TARI_ID_FILE"
    else
        log "Tari identity exists, skipping init."
    fi

    log "Starting minotari_node (pruning horizon: ${TARI_PRUNING_HORIZON})..."
    TARI_SCRIPT=/var/lib/tari/start-node.sh
    cat > "$TARI_SCRIPT" <<TARISCRIPT
#!/bin/sh
exec minotari_node \
    --non-interactive-mode \
    --mining-enabled \
    -p base_node.storage.pruning_horizon=${TARI_PRUNING_HORIZON} \
    -p base_node.grpc_enabled=true \
    -p base_node.grpc_address=/ip4/127.0.0.1/tcp/18102 \
    -p base_node.use_libtor=false \
    -p base_node.p2p.transport.type=tor \
    -p base_node.p2p.transport.tor.control_address=/ip4/127.0.0.1/tcp/9051 \
    -p base_node.p2p.transport.tor.control_auth=auto
TARISCRIPT
    chown tari:tari "$TARI_SCRIPT"
    chmod 750 "$TARI_SCRIPT"
    su -s /bin/sh tari -c "$TARI_SCRIPT" \
        >> /var/log/tari/tari-node.log 2>&1 &
    TARI_PID=$!

    log "Waiting for minotari_node gRPC on :18102..."
    until nc -z 127.0.0.1 18102 2>/dev/null; do sleep 3; done
    log "minotari_node gRPC is up."
fi

# ── resolve p2pool mode flag ──────────────────────────────────────────────────
case "$P2POOL_MODE" in
    main) MODE_FLAG="" ;;
    mini) MODE_FLAG="--mini" ;;
    nano) MODE_FLAG="--nano" ;;
    *)    log "Unknown P2POOL_MODE '$P2POOL_MODE'. Use: main | mini | nano"; exit 1 ;;
esac

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

log "All services running. monerod=$MONEROD_PID p2pool=$P2POOL_PID${TARI_PID:+ tari=$TARI_PID}${TOR_PID:+ tor=$TOR_PID}"
if [ -n "$MERGE_MINE_FLAG" ]; then
    log "  Tari merge mining → grpc://127.0.0.1:18102"
fi
if [ "$TOR_ENABLED" = "true" ]; then
    log "  monerod onion  RPC  : ${MONEROD_ONION}:18089"
    log "  monerod onion  P2P  : ${MONEROD_ONION}:18084"
    log "  p2pool stratum onion: ${STRATUM_ONION}:${STRATUM_PORT}"
    log "  tari P2P onion      : ${TARI_ONION}:18141"
fi

# ── log rotation ──────────────────────────────────────────────────────────────
LOG_MAX_SIZE="${LOG_MAX_SIZE:-500M}"
if [ "$LOG_MAX_SIZE" != "0" ]; then
    cat > /etc/logrotate.d/mining <<EOF
/var/log/p2pool/p2pool.log /var/log/monero/*.log /var/log/tari/tari-node.log /var/lib/tari/.tari/mainnet/log/base_node/network.log /var/lib/tari/.tari/mainnet/log/base_node/base_layer.log /var/lib/tari/.tari/mainnet/log/base_node/messages.log /var/lib/tari/.tari/mainnet/log/base_node/grpc.log /var/lib/tari/.tari/mainnet/log/base_node/other.log {
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

WAIT_PIDS=("$MONEROD_PID" "$P2POOL_PID")
[ -n "${TARI_PID:-}" ] && WAIT_PIDS+=("$TARI_PID")
[ -n "${TOR_PID:-}"  ] && WAIT_PIDS+=("$TOR_PID")
wait -n "${WAIT_PIDS[@]}"
log "A process exited unexpectedly. Shutting down..."
cleanup
