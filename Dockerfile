FROM debian:bookworm-slim

ARG MONERO_URL
ARG MONERO_SHA256
ARG P2POOL_URL
ARG P2POOL_SHA256

# ── deps ──────────────────────────────────────────────────────────────────────
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl wget tar bzip2 ca-certificates tor \
    && rm -rf /var/lib/apt/lists/*

# ── users ─────────────────────────────────────────────────────────────────────
RUN useradd --system --no-create-home monerod && \
    useradd --system --no-create-home p2pool

# ── monerod (with checksum verify) ───────────────────────────────────
RUN wget -q -O /tmp/monero.tar.bz2 "$MONERO_URL" && \
    echo "${MONERO_SHA256}  /tmp/monero.tar.bz2" | sha256sum -c - && \
    mkdir -p /tmp/monero && \
    tar -xf /tmp/monero.tar.bz2 -C /tmp/monero --strip-components=1 && \
    install -m 755 /tmp/monero/monerod /usr/local/bin/monerod && \
    rm -rf /tmp/monero /tmp/monero.tar.bz2

# ── p2pool (with checksum verify) ─────────────────────────────────────────────
RUN wget -q -O /tmp/p2pool.tar.gz "$P2POOL_URL" && \
    echo "${P2POOL_SHA256}  /tmp/p2pool.tar.gz" | sha256sum -c - && \
    mkdir -p /tmp/p2pool && \
    tar -xf /tmp/p2pool.tar.gz -C /tmp/p2pool --strip-components=1 && \
    install -m 755 /tmp/p2pool/p2pool /usr/local/bin/p2pool && \
    rm -rf /tmp/p2pool /tmp/p2pool.tar.gz

# ── directories ───────────────────────────────────────────────────────────────
RUN mkdir -p \
        /var/lib/monero/bitmonero /var/log/monero /etc/monero \
        /var/lib/p2pool /var/log/p2pool && \
    chown -R monerod:monerod /var/lib/monero /var/log/monero /etc/monero && \
    chown -R p2pool:p2pool   /var/lib/p2pool /var/log/p2pool

COPY monerod.conf /etc/monero/monerod.conf
RUN chown monerod:monerod /etc/monero/monerod.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# monerod: P2P 18080, RPC 18089, ZMQ 18083, onion-inbound 18084
# p2pool:  stratum 3333, p2p main 37889, mini/nano 37888
EXPOSE 18080 18084 18089 18083 3333 37889 37888

ENTRYPOINT ["/entrypoint.sh"]
