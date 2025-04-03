FROM golang:1.24 AS builder
WORKDIR /work
RUN git clone https://github.com/ethpandaops/eth-beacon-genesis.git  \
    && cd eth-beacon-genesis && make \
    && go install github.com/protolambda/eth2-val-tools@latest \
    && go install github.com/miguelmota/go-ethereum-hdwallet/cmd/geth-hdwallet@latest

FROM debian:latest
WORKDIR /work
VOLUME ["/config", "/data"]
EXPOSE 8000/tcp
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    ca-certificates gettext-base jq yq wget curl && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY apps /apps

ENV PATH="/root/.cargo/bin:${PATH}"
COPY --from=builder /work/eth-beacon-genesis/bin/eth-beacon-genesis /usr/local/bin/eth-beacon-genesis
COPY --from=builder /go/bin/eth2-val-tools /usr/local/bin/eth2-val-tools
COPY --from=builder /go/bin/geth-hdwallet /usr/local/bin/geth-hdwallet

COPY config-example /config
COPY defaults /defaults
COPY entrypoint.sh .
ENTRYPOINT [ "/work/entrypoint.sh" ]