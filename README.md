# p2pool + Tari merge mining (Docker)

Self-hosted Monero node + P2Pool with optional Tari merge mining and Tor hidden services.

## Requirements

- Docker, root/sudo
- 250 GB+ SSD recommended

## Quick start
```bash
cp setup.conf.example setup.conf
# Edit: set WALLET, verify binary URLs/checksums, adjust options
sudo ./manage.sh build
sudo ./manage.sh start
```

## Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `WALLET` | Yes | - | Monero wallet address |
| `MONERO_URL` / `MONERO_SHA256` | Yes | - | monerod binary URL and SHA-256 |
| `P2POOL_URL` / `P2POOL_SHA256` | Yes | - | p2pool binary URL and SHA-256 |
| `P2POOL_MODE` | Yes | - | `main`, `mini`, or `nano` |
| `MONERO_PRUNED` | No | `true` | `false` = full archival node |
| `TARI_WALLET` | No | - | Tari wallet address, enables merge mining if set |
| `TARI_IMAGE` | No | `quay.io/tarilabs/minotari_node:latest-mainnet` | Tari Docker image |
| `TARI_MEMORY` | No | `2g` | RAM cap for Tari container |
| `TARI_PRUNING_HORIZON` | No | `1000` | Blocks to retain (`0` = full node) |
| `TARI_GRPC_PORT` | No | `18142` | Tari gRPC port |
| `TARI_P2P_PORT` | No | `18141` | Tari P2P port |
| `TOR_ENABLED` | No | `false` | `true` to enable Tor hidden services |
| `LOG_MAX_SIZE` | No | `500M` | Max log file size before rotation (`0` to disable) |

Verify checksums against official release pages before updating URLs:
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
| 18141 | Tari P2P (configurable) |
| 18142 | Tari gRPC (configurable, internal) |

## Tor

When `TOR_ENABLED=true`, hidden services are created for monerod RPC, monerod P2P, and p2pool stratum:
```bash
sudo ./manage.sh onions
```

## Tari merge mining

Set `TARI_WALLET` to enable. A `tari-node` sidecar container starts automatically alongside the main container. p2pool is started with `--merge-mine` and handles connectivity to the Tari node natively, no additional monitoring is needed.

## Log rotation

Logs are rotated automatically when they reach `LOG_MAX_SIZE` (default `500M`). One compressed archive is kept alongside the live file, then discarded on the next rotation. Set `LOG_MAX_SIZE=0` in `setup.conf` to disable entirely.

## Volumes

| Volume | Contents |
|---|---|
| `monerod-data` | Monero blockchain |
| `tor-data` | Tor hidden service keys |
| `tari-data` | Tari blockchain |

`purge` removes all three, full re-sync required afterward.
