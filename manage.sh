#!/usr/bin/env bash
# manage.sh — build / run / stop / purge the monerod+p2pool container
set -euo pipefail

IMAGE="monerod-p2pool"
CONTAINER="monerod-p2pool"
DATA_VOL="monerod-data"
TOR_VOL="tor-data"
CONF="$(dirname "$0")/setup.conf"

usage() {
    cat <<HELP
Usage: $0 <command>

Commands:
  build    Build the Docker image (reads setup.conf; removes old image first)
  start    Start the container (reads setup.conf)
  stop     Stop and remove the container
  restart  stop + start
  logs     Tail container logs
  status   Show container status
  shell    Open a shell in the running container
  onions   Show Tor hidden-service onion addresses (requires TOR_ENABLED=true)
  purge    Remove container, image, AND blockchain data volume
HELP
    exit 1
}

load_conf() {
    [ -f "$CONF" ] || { echo "[!] setup.conf not found at $CONF"; exit 1; }
    # shellcheck disable=SC1090
    source "$CONF"
    [ -n "${WALLET:-}"        ] || { echo "[!] WALLET is not set in setup.conf";        exit 1; }
    [ -n "${MONERO_URL:-}"    ] || { echo "[!] MONERO_URL is not set in setup.conf";    exit 1; }
    [ -n "${P2POOL_URL:-}"    ] || { echo "[!] P2POOL_URL is not set in setup.conf";    exit 1; }
    [ -n "${P2POOL_SHA256:-}" ] || { echo "[!] P2POOL_SHA256 is not set in setup.conf"; exit 1; }
    [ -n "${P2POOL_MODE:-}"   ] || { echo "[!] P2POOL_MODE is not set in setup.conf";   exit 1; }
    TOR_ENABLED="${TOR_ENABLED:-false}"
    # MONERO_SHA256 is optional (but strongly recommended)
    MONERO_SHA256="${MONERO_SHA256:-}"
}

cmd_build() {
    load_conf
    # Always remove the existing image before rebuilding so that a version bump
    # in setup.conf (new URL / checksum) never silently reuses stale layers.
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "[*] Removing existing image '$IMAGE' to ensure a clean rebuild..."
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

cmd_start() {
    load_conf
    docker volume inspect "$DATA_VOL" >/dev/null 2>&1 || docker volume create "$DATA_VOL"
    docker volume inspect "$TOR_VOL"  >/dev/null 2>&1 || docker volume create "$TOR_VOL"
    echo "[*] Starting container: $CONTAINER"
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        -e "WALLET=${WALLET}" \
        -e "P2POOL_MODE=${P2POOL_MODE}" \
        -e "TOR_ENABLED=${TOR_ENABLED}" \
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
    echo "[*] Stopping $CONTAINER..."
    docker stop "$CONTAINER" 2>/dev/null && docker rm "$CONTAINER" 2>/dev/null || true
}

cmd_logs()    { docker logs --tail 500 -f "$CONTAINER"; }
cmd_status()  { docker ps -a --filter "name=${CONTAINER}" \
                    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; }
cmd_shell()   { docker exec -it "$CONTAINER" /bin/bash; }
cmd_restart() { cmd_stop; cmd_start; }

cmd_onions() {
    load_conf
    if [ "${TOR_ENABLED}" != "true" ]; then
        echo "[!] TOR_ENABLED is not 'true' in setup.conf — no onion addresses configured."
        exit 1
    fi

    # Try reading from the named tor-data volume via a throw-away container first
    # (works even when the main container is stopped).  Fall back to exec if the
    # volume doesn't exist yet (container has never been started).
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
    echo "[!] WARNING: Deletes container, image, AND blockchain data (full re-sync required)."
    read -rp "[?] Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "[*] Aborted."; exit 0; }
    docker stop      "$CONTAINER" 2>/dev/null || true
    docker rm        "$CONTAINER" 2>/dev/null || true
    docker rmi       "$IMAGE"     2>/dev/null || true
    docker volume rm "$DATA_VOL"  2>/dev/null || true
    docker volume rm "$TOR_VOL"   2>/dev/null || true
    echo "[*] Purge complete."
}

[ $# -lt 1 ] && usage
case "$1" in
    build)   cmd_build   ;;
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    logs)    cmd_logs    ;;
    status)  cmd_status  ;;
    shell)   cmd_shell   ;;
    onions)  cmd_onions  ;;
    purge)   cmd_purge   ;;
    *)       usage       ;;
esac
