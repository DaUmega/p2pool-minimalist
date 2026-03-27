#!/usr/bin/env bash
# manage.sh — build / run / stop / purge the monerod+p2pool+p2pool container

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
  build        Build the Docker image
  start        Start the container
  stop         Stop and remove container
  restart      Stop + start
  attach       Attach to a service tmux session
  shell        Open shell in container
  status       Show container status
  onions       Show Tor hidden-service onion addresses
  purge        Remove ALL containers, images, volumes, and network (destructive!)
HELP
    exit 1
}

load_conf() {
    [ -f "$CONF" ] || { echo "[!] setup.conf not found at $CONF"; exit 1; }
    # shellcheck disable=SC1090
    source "$CONF"

    [ -n "${WALLET:-}"        ] || { echo "[!] WALLET is not set";        exit 1; }
    [ -n "${MONERO_URL:-}"    ] || { echo "[!] MONERO_URL is not set";    exit 1; }
    [ -n "${MONERO_SHA256:-}" ] || { echo "[!] MONERO_SHA256 is not set"; exit 1; }
    [ -n "${P2POOL_URL:-}"    ] || { echo "[!] P2POOL_URL is not set";    exit 1; }
    [ -n "${P2POOL_SHA256:-}" ] || { echo "[!] P2POOL_SHA256 is not set"; exit 1; }
    [ -n "${TARI_URL:-}"      ] || { echo "[!] TARI_URL is not set";      exit 1; }
    [ -n "${TARI_SHA256:-}"   ] || { echo "[!] TARI_SHA256 is not set";   exit 1; }
    [ -n "${P2POOL_MODE:-}"   ] || { echo "[!] P2POOL_MODE is not set";   exit 1; }

    TOR_ENABLED="${TOR_ENABLED:-false}"
    TARI_WALLET="${TARI_WALLET:-}"
    TARI_MEMORY="${TARI_MEMORY:-3g}"
}

ensure_network() {
    docker network inspect "$MINING_NET" >/dev/null 2>&1 || {
        echo "[*] Creating Docker network: $MINING_NET"
        docker network create "$MINING_NET"
    }
}

cmd_build() {
    load_conf
    docker rmi "$IMAGE" 2>/dev/null || true

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

    docker run -dit \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --network "$MINING_NET" \
        --memory "$TARI_MEMORY" \
        -e "WALLET=${WALLET}" \
        -e "MONERO_PRUNED=${MONERO_PRUNED:-true}" \
        -e "P2POOL_MODE=${P2POOL_MODE}" \
        -e "TOR_ENABLED=${TOR_ENABLED}" \
        -e "TARI_WALLET=${TARI_WALLET}" \
        -v "${DATA_VOL}:/var/lib/monero" \
        -v "${TOR_VOL}:/var/lib/tor" \
        -v "${TARI_VOL}:/var/lib/tari" \
        -p 18080:18080 \
        -p 18084:18084 \
        -p 18089:18089 \
        -p 3333:3333 \
        -p 37889:37889 \
        -p 37888:37888 \
        -p 18142:18142 \
        "$IMAGE"

    echo "[*] Started. Use: sudo $0 attach"
}

cmd_stop() {
    echo "[*] Stopping $CONTAINER..."
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
}

cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

cmd_attach() {
    echo "[*] Select attach target:"
    echo "  [1] Container output (monerod / tor / entrypoint) — detach: Ctrl+P then Q"
    echo "  [2] p2pool (tmux)                                 — detach: Ctrl+P then Q"
    echo "  [3] tari   (tmux)                                 — detach: Ctrl+P then Q"
    echo ""
    echo "  !! WARNING: DO NOT USE CTRL+C — IT WILL KILL THE PROCESS !!"
    echo "  !! If you do, run: sudo ./manage.sh restart !!"
    echo ""
    read -rp "Enter choice: " CHOICE

    case "$CHOICE" in
        1) exec docker attach "$CONTAINER" ;;
        2) exec docker exec -it "$CONTAINER" tmux attach -t p2pool ;;
        3) exec docker exec -it "$CONTAINER" tmux attach -t tari   ;;
        *) echo "[!] Invalid choice"; exit 1 ;;
    esac
}

cmd_shell() {
    docker exec -it "$CONTAINER" /bin/bash
}

cmd_status() {
    docker ps -a \
        --filter "name=${CONTAINER}" \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

cmd_onions() {
    load_conf

    if [ "${TOR_ENABLED}" != "true" ]; then
        echo "[!] TOR not enabled."
        exit 1
    fi

    docker exec "$CONTAINER" sh -c '
        echo "monerod onion:"
        cat /var/lib/tor/monerod/hostname 2>/dev/null || echo "<not ready>"
        echo ""
        echo "p2pool onion:"
        cat /var/lib/tor/p2pool-stratum/hostname 2>/dev/null || echo "<not ready>"
    '
}

cmd_purge() {
    echo "[!] WARNING: This deletes EVERYTHING including blockchain data."
    read -rp "Type 'yes' to continue: " CONFIRM
    [ "$CONFIRM" = "yes" ] || exit 0

    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
    docker rmi  "$IMAGE"     2>/dev/null || true
    docker volume rm "$DATA_VOL" "$TOR_VOL" "$TARI_VOL" 2>/dev/null || true
    docker network rm "$MINING_NET" 2>/dev/null || true

    echo "[*] Purge complete."
}

[ $# -lt 1 ] && usage

case "$1" in
    build)   cmd_build   ;;
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    attach)  cmd_attach  ;;
    shell)   cmd_shell   ;;
    status)  cmd_status  ;;
    onions)  cmd_onions  ;;
    purge)   cmd_purge   ;;
    *)       usage       ;;
esac
