FROM debian:bookworm-slim

ARG MONERO_URL
ARG MONERO_SHA256
ARG P2POOL_URL
ARG P2POOL_SHA256
ARG TARI_URL
ARG TARI_SHA256

# ── deps ──────────────────────────────────────────────────────────────────────
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl wget tar bzip2 unzip ca-certificates tor tmux \
    && rm -rf /var/lib/apt/lists/*

# ── users ─────────────────────────────────────────────────────────────────────
RUN useradd --system --no-create-home monerod && \
    useradd --system --no-create-home p2pool  && \
    useradd --system --create-home --home-dir /var/lib/tari tari

# ── monerod ───────────────────────────────────────────────────────────────────
RUN wget -q -O /tmp/monero.tar.bz2 "$MONERO_URL" && \
    echo "${MONERO_SHA256}  /tmp/monero.tar.bz2" | sha256sum -c - && \
    tar -xf /tmp/monero.tar.bz2 -C /tmp --strip-components=1 && \
    install -m 755 /tmp/monerod /usr/local/bin/monerod && \
    rm -rf /tmp/monero* /tmp/monerod*

# ── p2pool ────────────────────────────────────────────────────────────────────
RUN wget -q -O /tmp/p2pool.tar.gz "$P2POOL_URL" && \
    echo "${P2POOL_SHA256}  /tmp/p2pool.tar.gz" | sha256sum -c - && \
    tar -xf /tmp/p2pool.tar.gz -C /tmp --strip-components=1 && \
    install -m 755 /tmp/p2pool /usr/local/bin/p2pool && \
    rm -rf /tmp/p2pool*

# ── minotari_node ─────────────────────────────────────────────────────────────
RUN wget -q -O /tmp/tari.zip "$TARI_URL" && \
    echo "${TARI_SHA256}  /tmp/tari.zip" | sha256sum -c - && \
    unzip -q /tmp/tari.zip -d /tmp/tari && \
    install -m 755 /tmp/tari/minotari_node /usr/local/bin/minotari_node && \
    rm -rf /tmp/tari*

# ── directories ───────────────────────────────────────────────────────────────
RUN mkdir -p \
        /var/lib/monero/bitmonero /var/log/monero /etc/monero \
        /var/lib/p2pool /var/log/p2pool \
        /var/lib/tari   /var/log/tari && \
    chown -R monerod:monerod /var/lib/monero /var/log/monero /etc/monero && \
    chown -R p2pool:p2pool   /var/lib/p2pool /var/log/p2pool && \
    chown -R tari:tari       /var/lib/tari   /var/log/tari

COPY monerod.conf /etc/monero/monerod.conf
RUN chown monerod:monerod /etc/monero/monerod.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# monerod: P2P 18080, onion-inbound 18084, RPC 18089
# p2pool:  stratum 3333, p2p main 37889, mini/nano 37888
# tari:    P2P 18141
# (internal-only: monerod ZMQ 18083, tari gRPC 18142)
EXPOSE 18080 18084 18089 3333 37889 37888 18141

ENTRYPOINT ["/entrypoint.sh"]
