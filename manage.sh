#!/usr/bin/env bash
# manage.sh — build / run / stop / purge the monerod+p2pool+tari containers
set -euo pipefail

# ── root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] This script must be run as root (or via sudo)."
    exit 1
fi

IMAGE="p2pool-mining"
CONTAINER="p2pool-mining"
DATA_VOL="monerod-data"
TOR_VOL="tor-data"
TARI_VOL="tari-data"
MINING_NET="mining-net"
CONF="$(dirname "$0")/setup.conf"

usage() {
    cat <<HELP
Usage: $0 <command>

Commands:
  build        Build the monerod+p2pool+tari Docker image
  start        Start the container
  stop         Stop the container
  restart      stop + start
  logs         Tail monerod+p2pool container logs
  logs-tari    Tail minotari_node logs (inside the container)
  status       Show container status
  shell        Open a shell in the container
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
    [ -n "${TARI_URL:-}"      ] || { echo "[!] TARI_URL is not set in setup.conf";      exit 1; }
    [ -n "${TARI_SHA256:-}"   ] || { echo "[!] TARI_SHA256 is not set in setup.conf";   exit 1; }
    [ -n "${P2POOL_MODE:-}"   ] || { echo "[!] P2POOL_MODE is not set in setup.conf";   exit 1; }
    TOR_ENABLED="${TOR_ENABLED:-false}"
    TARI_WALLET="${TARI_WALLET:-}"
    TARI_MEMORY="${TARI_MEMORY:-3g}"
    TARI_PRUNING_HORIZON="${TARI_PRUNING_HORIZON:-1000}"
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
        --build-arg "MONERO_SHA256=${MONERO_SHA256}" \
        --build-arg "P2POOL_URL=${P2POOL_URL}" \
        --build-arg "P2POOL_SHA256=${P2POOL_SHA256}" \
        --build-arg "TARI_URL=${TARI_URL}" \
        --build-arg "TARI_SHA256=${TARI_SHA256}" \
        -t "$IMAGE" "$(dirname "$0")"
    echo "[*] Build complete."
}

cmd_start() {
    load_conf
    ensure_network
    docker volume inspect "$DATA_VOL" >/dev/null 2>&1 || docker volume create "$DATA_VOL"
    docker volume inspect "$TOR_VOL"  >/dev/null 2>&1 || docker volume create "$TOR_VOL"
    docker volume inspect "$TARI_VOL" >/dev/null 2>&1 || docker volume create "$TARI_VOL"

    echo "[*] Starting container: $CONTAINER"
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --network "$MINING_NET" \
        -e "WALLET=${WALLET}" \
        -e "MONERO_PRUNED=${MONERO_PRUNED:-true}" \
        -e "P2POOL_MODE=${P2POOL_MODE}" \
        -e "TOR_ENABLED=${TOR_ENABLED}" \
        -e "TARI_WALLET=${TARI_WALLET}" \
        -e "TARI_PRUNING_HORIZON=${TARI_PRUNING_HORIZON}" \
        ${TARI_WALLET:+--memory "${TARI_MEMORY}"} \
        ${TARI_WALLET:+--memory-swap "${TARI_MEMORY}"} \
        -v "${DATA_VOL}:/var/lib/monero" \
        -v "${TOR_VOL}:/var/lib/tor" \
        -v "${TARI_VOL}:/var/lib/tari" \
        -p 18080:18080 \
        -p 18084:18084 \
        -p 18089:18089 \
        -p 3333:3333 \
        -p 37889:37889 \
        -p 37888:37888 \
        -p 18141:18141 \
        -p 18142:18142 \
        "$IMAGE"
    echo "[*] Started. Run: $0 logs"
}

cmd_stop() {
    echo "[*] Stopping $CONTAINER..."
    docker stop "$CONTAINER" 2>/dev/null && docker rm "$CONTAINER" 2>/dev/null || true
}

cmd_logs() { docker logs --tail 500 -f "$CONTAINER"; }
cmd_logs_tari() {
    docker exec "$CONTAINER" \
        tail -n 500 -f /var/log/tari/tari-node.log
}
cmd_shell()   { docker exec -it "$CONTAINER" /bin/bash; }
cmd_restart() { cmd_stop; sleep 2; load_conf; cmd_start; }

cmd_status() {
    echo "=== Mining container ==="
    docker ps -a \
        --filter "name=${CONTAINER}" \
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
    TARI_ONION=$(read_onion /var/lib/tor/tari/hostname)

    echo "  ── monerod hidden service ──────────────────────────────────────"
    echo "  RPC  (connect your wallet) : ${MONEROD_ONION}:18089"
    echo "  P2P  (anonymous peer)      : ${MONEROD_ONION}:18084"
    echo ""
    echo "  ── p2pool stratum hidden service ───────────────────────────────"
    echo "  Stratum (miner)            : ${STRATUM_ONION}:3333"
    echo ""
    echo "  ── tari P2P hidden service ─────────────────────────────────────"
    echo "  P2P                        : ${TARI_ONION}:18141"
}

cmd_purge() {
    load_conf
    echo "[!] WARNING: Deletes ALL containers, images, and blockchain data."
    echo "[!]          Full re-sync of Monero and Tari will be required."
    read -rp "[?] Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "[*] Aborted."; exit 0; }
    docker stop      "$CONTAINER" 2>/dev/null || true
    docker rm        "$CONTAINER" 2>/dev/null || true
    docker rmi       "$IMAGE"     2>/dev/null || true
    docker volume rm "$DATA_VOL"  2>/dev/null || true
    docker volume rm "$TOR_VOL"   2>/dev/null || true
    docker volume rm "$TARI_VOL"  2>/dev/null || true
    docker network rm "$MINING_NET" 2>/dev/null || true
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
