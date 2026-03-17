#!/usr/bin/env bash
# manage.sh — build / run / stop / purge the monerod+p2pool+tari containers
set -euo pipefail

# ── root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] This script must be run as root (or via sudo)."
    exit 1
fi

IMAGE="monerod-p2pool"
CONTAINER="monerod-p2pool"
TARI_CONTAINER="tari-node"
DATA_VOL="monerod-data"
TOR_VOL="tor-data"
TARI_VOL="tari-data"
MINING_NET="mining-net"
CONF="$(dirname "$0")/setup.conf"

usage() {
    cat <<HELP
Usage: $0 <command>

Commands:
  build        Build the monerod+p2pool Docker image
  start        Start all containers (tari if TARI_WALLET is set, then monerod+p2pool)
  stop         Stop all containers
  restart      stop + start
  logs         Tail monerod+p2pool container logs
  logs-tari    Tail Tari base node logs
  status       Show status of all containers
  shell        Open a shell in the monerod+p2pool container
  onions       Show Tor hidden-service onion addresses
  purge        Remove ALL containers, images, and data volumes (destructive!)
HELP
    exit 1
}

load_conf() {
    [ -f "$CONF" ] || { echo "[!] setup.conf not found at $CONF"; exit 1; }
    # shellcheck disable=SC1090
    source "$CONF"
    [ -n "${WALLET:-}"        ] || { echo "[!] WALLET is not set in setup.conf";        exit 1; }
    [ -n "${MONERO_URL:-}"    ] || { echo "[!] MONERO_URL is not set in setup.conf";    exit 1; }
    [ -n "${MONERO_SHA256:-}" ] || { echo "[!] MONERO_SHA256 is not set in setup.conf"; exit 1; }
    [ -n "${P2POOL_URL:-}"    ] || { echo "[!] P2POOL_URL is not set in setup.conf";    exit 1; }
    [ -n "${P2POOL_SHA256:-}" ] || { echo "[!] P2POOL_SHA256 is not set in setup.conf"; exit 1; }
    [ -n "${P2POOL_MODE:-}"   ] || { echo "[!] P2POOL_MODE is not set in setup.conf";   exit 1; }
    TOR_ENABLED="${TOR_ENABLED:-false}"
    TARI_WALLET="${TARI_WALLET:-}"
    # Tari resource limits — override in setup.conf
    TARI_MEMORY="${TARI_MEMORY:-2g}"
    TARI_PRUNING_HORIZON="${TARI_PRUNING_HORIZON:-1000}"
    if [ -n "$TARI_WALLET" ]; then
        TARI_IMAGE="${TARI_IMAGE:-quay.io/tarilabs/minotari_node:latest-mainnet}"
    else
        TARI_IMAGE=""
    fi
}

ensure_network() {
    docker network inspect "$MINING_NET" >/dev/null 2>&1 || {
        echo "[*] Creating Docker network: $MINING_NET"
        docker network create "$MINING_NET"
    }
}

cmd_build() {
    load_conf
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "[*] Removing existing image '$IMAGE' for clean rebuild..."
        docker rmi "$IMAGE" 2>/dev/null || true
    fi
    echo "[*] Building image: $IMAGE"
    docker build \
        --no-cache \
        --build-arg "MONERO_URL=${MONERO_URL}" \
        ${MONERO_SHA256:+--build-arg "MONERO_SHA256=${MONERO_SHA256}"} \
        --build-arg "P2POOL_URL=${P2POOL_URL}" \
        --build-arg "P2POOL_SHA256=${P2POOL_SHA256}" \
        -t "$IMAGE" "$(dirname "$0")"
    echo "[*] Build complete."
}

_ensure_tari() {
    [ -z "$TARI_IMAGE" ] && return 0  # No merge mining
    ensure_network
    docker volume inspect "$TARI_VOL" >/dev/null 2>&1 || docker volume create "$TARI_VOL"
    if ! docker ps --format '{{.Names}}' | grep -q "^${TARI_CONTAINER}$"; then
        echo "[*] Starting Tari base node: $TARI_CONTAINER (memory: ${TARI_MEMORY}, pruning horizon: ${TARI_PRUNING_HORIZON})"
        docker run -d \
            --name "$TARI_CONTAINER" \
            --restart unless-stopped \
            --network "$MINING_NET" \
            -e TARI_NETWORK=mainnet \
            -v "${TARI_VOL}:/root/.tari" \
            -p 18141:18141 \
            --memory "${TARI_MEMORY}" \
            --memory-swap "${TARI_MEMORY}" \
            -it \
            "$TARI_IMAGE" \
            --non-interactive-mode \
            --mining-enabled \
            -p storage.pruning_horizon="${TARI_PRUNING_HORIZON}" \
            -p base_node.grpc_enabled=true \
            -p base_node.grpc_address="/ip4/0.0.0.0/tcp/18142"
    fi
}

_stop_tari() {
    [ -z "$TARI_IMAGE" ] && return 0
    echo "[*] Stopping Tari container: $TARI_CONTAINER"
    docker stop "$TARI_CONTAINER" 2>/dev/null && docker rm "$TARI_CONTAINER" 2>/dev/null || true
}

cmd_start() {
    load_conf
    ensure_network
    docker volume inspect "$DATA_VOL" >/dev/null 2>&1 || docker volume create "$DATA_VOL"
    docker volume inspect "$TOR_VOL"  >/dev/null 2>&1 || docker volume create "$TOR_VOL"

    _ensure_tari

    # Determine Tari node hostname on the shared network
    TARI_NODE_HOST=""
    if [ -n "$TARI_WALLET" ]; then
        TARI_NODE_HOST="$TARI_CONTAINER"
        echo "[*] Tari merge mining enabled → node: $TARI_NODE_HOST"
    fi

    echo "[*] Starting container: $CONTAINER"
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --network "$MINING_NET" \
        -e "WALLET=${WALLET}" \
        -e "P2POOL_MODE=${P2POOL_MODE}" \
        -e "TOR_ENABLED=${TOR_ENABLED}" \
        -e "TARI_WALLET=${TARI_WALLET}" \
        -e "TARI_NODE_HOST=${TARI_NODE_HOST}" \
        -v "${DATA_VOL}:/var/lib/monero" \
        -v "${TOR_VOL}:/var/lib/tor" \
        -p 18080:18080 \
        -p 18084:18084 \
        -p 18089:18089 \
        -p 3333:3333 \
        -p 37889:37889 \
        -p 37888:37888 \
        "$IMAGE"
    echo "[*] Started. Run: $0 logs"
}

cmd_stop() {
    load_conf
    echo "[*] Stopping $CONTAINER..."
    docker stop "$CONTAINER" 2>/dev/null && docker rm "$CONTAINER" 2>/dev/null || true
    _stop_tari
}

cmd_logs()      { docker logs --tail 500 -f "$CONTAINER"; }
cmd_logs_tari() { docker logs --tail 500 -f "$TARI_CONTAINER"; }
cmd_shell()     { docker exec -it "$CONTAINER" /bin/bash; }
cmd_restart()   { cmd_stop; sleep 2; cmd_start; }

cmd_status() {
    echo "=== All mining containers ==="
    docker ps -a \
        --filter "name=${CONTAINER}" \
        --filter "name=${TARI_CONTAINER}" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_onions() {
    load_conf
    if [ "${TOR_ENABLED}" != "true" ]; then
        echo "[!] TOR_ENABLED is not 'true' in setup.conf — no onion addresses configured."
        exit 1
    fi

    read_onion() {
        local path="$1"
        if docker volume inspect "$TOR_VOL" >/dev/null 2>&1; then
            docker run --rm \
                -v "${TOR_VOL}:/var/lib/tor:ro" \
                --entrypoint sh \
                "$IMAGE" -c "cat '${path}' 2>/dev/null" \
                | tr -d '[:space:]' 2>/dev/null || echo "<not generated yet>"
        else
            docker exec "$CONTAINER" cat "$path" 2>/dev/null \
                | tr -d '[:space:]' || echo "<not generated yet>"
        fi
    }

    MONEROD_ONION=$(read_onion /var/lib/tor/monerod/hostname)
    STRATUM_ONION=$(read_onion /var/lib/tor/p2pool-stratum/hostname)

    echo "  ── monerod hidden service ──────────────────────────────────────"
    echo "  RPC  (connect your wallet) : ${MONEROD_ONION}:18089"
    echo "  P2P  (anonymous peer)      : ${MONEROD_ONION}:18084"
    echo ""
    echo "  ── p2pool stratum hidden service ───────────────────────────────"
    echo "  Stratum (miner)            : ${STRATUM_ONION}:3333"
}

cmd_purge() {
    load_conf
    echo "[!] WARNING: Deletes ALL containers, images, and blockchain data."
    echo "[!]          Full re-sync of both Monero and Tari will be required."
    read -rp "[?] Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "[*] Aborted."; exit 0; }
    docker stop      "$CONTAINER"      2>/dev/null || true
    docker rm        "$CONTAINER"      2>/dev/null || true
    docker stop      "$TARI_CONTAINER" 2>/dev/null || true
    docker rm        "$TARI_CONTAINER" 2>/dev/null || true
    docker rmi       "$IMAGE"          2>/dev/null || true
    docker volume rm "$DATA_VOL"       2>/dev/null || true
    docker volume rm "$TOR_VOL"        2>/dev/null || true
    docker volume rm "$TARI_VOL"       2>/dev/null || true
    docker network rm "$MINING_NET"    2>/dev/null || true
    echo "[*] Purge complete."
}

[ $# -lt 1 ] && usage
case "$1" in
    build)      cmd_build      ;;
    start)      cmd_start      ;;
    stop)       cmd_stop       ;;
    restart)    cmd_restart    ;;
    logs)       cmd_logs       ;;
    logs-tari)  cmd_logs_tari  ;;
    status)     cmd_status     ;;
    shell)      cmd_shell      ;;
    onions)     cmd_onions     ;;
    purge)      cmd_purge      ;;
    *)          usage          ;;
esac
