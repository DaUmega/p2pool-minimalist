# monerod-p2pool

Self-hosted Monero full node + P2Pool decentralized mining, containerized with Docker. Optionally enables Tari merge mining and Tor hidden services.

## What's included

- **monerod** — pruned Monero full node with restricted RPC
- **p2pool** — decentralized Monero mining (main / mini / nano)
- **Tari merge mining** — optional; runs a sidecar `minotari_node` container and auto-enables/disables based on node availability
- **Tor** — optional; routes outbound transactions and exposes monerod RPC+P2P and p2pool stratum as hidden services

## Requirements

- Docker
- Root / sudo access
- ~100 GB disk (pruned Monero chain) + ~20 GB (Tari, if enabled)

## Quick start
```bash
cp setup.conf.example setup.conf
# Edit setup.conf: set WALLET, update binary URLs/checksums, configure options
sudo ./manage.sh build
sudo ./manage.sh start
```

## setup.conf

| Variable | Required | Description |
|---|---|---|
| `WALLET` | Yes | Monero wallet address for mining rewards |
| `MONERO_URL` / `MONERO_SHA256` | Yes | monerod binary download URL and SHA-256 |
| `P2POOL_URL` / `P2POOL_SHA256` | Yes | p2pool binary download URL and SHA-256 |
| `P2POOL_MODE` | Yes | `main`, `mini`, or `nano` |
| `TARI_WALLET` | No | Tari wallet address — enables merge mining if set |
| `TARI_MEMORY` | No | RAM cap for Tari container (default: `3g`) |
| `TARI_PRUNING_HORIZON` | No | Blocks to retain in Tari node (default: `2000`) |
| `TOR_ENABLED` | No | `true` to enable Tor hidden services |

Binary checksums must match the downloaded files. Verify against official release pages:
- Monero: https://www.getmonero.org/downloads/
- p2pool: https://github.com/SChernykh/p2pool/releases

## manage.sh commands
```
build        Build the monerod+p2pool Docker image
start        Start all containers
stop         Stop all containers
restart      stop + start
logs         Tail monerod+p2pool logs
logs-tari    Tail Tari base node logs
status       Show container status
shell        Open a shell in the monerod+p2pool container
onions       Print Tor hidden service addresses (requires TOR_ENABLED=true)
purge        Remove all containers, images, and volumes (destructive)
```

## Ports

| Port | Service |
|---|---|
| 18080 | monerod P2P |
| 18089 | monerod restricted RPC |
| 18083 | monerod ZMQ (internal) |
| 18084 | monerod anonymous-inbound (Tor) |
| 3333 | p2pool stratum |
| 37889 | p2pool P2P (main) |
| 37888 | p2pool P2P (mini/nano) |
| 18141 | Tari P2P (if enabled) |
| 18142 | Tari gRPC (internal) |

## Tor hidden services

When `TOR_ENABLED=true`, three hidden services are created:

- **monerod RPC** — for wallet connections over Tor
- **monerod P2P** — anonymous peer advertising
- **p2pool stratum** — for miners connecting over Tor

Retrieve addresses after startup:
```bash
sudo ./manage.sh onions
```

## Tari merge mining

Set `TARI_WALLET` in `setup.conf` to enable. A `tari-node` container starts automatically alongside the main container. The entrypoint monitors gRPC connectivity every 30 seconds and restarts p2pool with or without `--merge-mine` as the Tari node goes up or down — no manual intervention required.

## Data persistence

| Volume | Contents |
|---|---|
| `monerod-data` | Monero blockchain |
| `tor-data` | Tor hidden service keys |
| `tari-data` | Tari blockchain |

`purge` removes all three. A full re-sync will be required afterward.
