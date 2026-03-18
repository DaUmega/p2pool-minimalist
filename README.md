# p2pool + Tari merge mining (Docker)

Self-hosted Monero node + P2Pool, containerized. Optionally enables Tari merge mining and Tor hidden services.

## Includes

- **monerod** — pruned or full Monero node with restricted RPC
- **p2pool** — decentralized mining (main / mini / nano)
- **Tari merge mining** — optional sidecar container; auto-enables/disables on node availability
- **Tor** — optional; anonymous outbound tx + hidden services for RPC, P2P, and stratum

## Requirements

- Docker, root/sudo
- Disk: recommend at least 250 GB with SSD

## Quick start
```bash
cp setup.conf.example setup.conf
# Set WALLET, update binary URLs/checksums, configure options
sudo ./manage.sh build
sudo ./manage.sh start
```

## setup.conf

| Variable | Required | Description |
|---|---|---|
| `WALLET` | Yes | Monero wallet address |
| `MONERO_URL` / `MONERO_SHA256` | Yes | monerod binary URL and SHA-256 |
| `P2POOL_URL` / `P2POOL_SHA256` | Yes | p2pool binary URL and SHA-256 |
| `P2POOL_MODE` | Yes | `main`, `mini`, or `nano` |
| `MONERO_PRUNED` | No | `true` (default) = pruned node, `false` = full archival |
| `TARI_WALLET` | No | Tari wallet address — enables merge mining if set |
| `TARI_MEMORY` | No | RAM cap for Tari container (default: `3g`) |
| `TARI_PRUNING_HORIZON` | No | Blocks to retain in Tari node (default: `2000`) |
| `TOR_ENABLED` | No | `true` to enable Tor hidden services |

Verify checksums against official release pages:
- Monero: https://www.getmonero.org/downloads/
- p2pool: https://github.com/SChernykh/p2pool/releases

## Commands
```
build        Build the Docker image
start        Start all containers
stop         Stop all containers
restart      stop + start
logs         Tail monerod+p2pool logs
logs-tari    Tail Tari logs
status       Show container status
shell        Shell into the main container
onions       Print Tor hidden service addresses
purge        Remove all containers, images, and volumes (destructive)
```

## Ports

| Port | Service |
|---|---|
| 18080 | monerod P2P |
| 18089 | monerod restricted RPC |
| 18084 | monerod anonymous-inbound (Tor) |
| 3333 | p2pool stratum |
| 37889 | p2pool P2P (main) |
| 37888 | p2pool P2P (mini/nano) |
| 18141 | Tari P2P |
| 18142 | Tari gRPC (internal) |

## Tor

When `TOR_ENABLED=true`, hidden services are created for monerod RPC, monerod P2P, and p2pool stratum. Retrieve addresses after startup:
```bash
sudo ./manage.sh onions
```

## Tari merge mining

Set `TARI_WALLET` to enable. A `tari-node` container starts automatically. The entrypoint monitors gRPC every 30 seconds and restarts p2pool with or without `--merge-mine` as the node goes up or down.

## Volumes

| Volume | Contents |
|---|---|
| `monerod-data` | Monero blockchain |
| `tor-data` | Tor hidden service keys |
| `tari-data` | Tari blockchain |

`purge` removes all three and requires a full re-sync.
