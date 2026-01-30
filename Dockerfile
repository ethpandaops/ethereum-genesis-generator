FROM golang:1.25 AS builder
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
    ca-certificates gettext-base yq wget curl bc && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY apps /apps

# Install jq with architecture detection
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        curl -L https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64 -o /usr/local/bin/jq; \
    elif [ "$ARCH" = "arm64" ]; then \
        curl -L https://github.com/jqlang/jq/releases/latest/download/jq-linux-arm64 -o /usr/local/bin/jq; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/jq

ENV PATH="/root/.cargo/bin:${PATH}"
COPY --from=builder /work/eth-beacon-genesis/bin/eth-genesis-state-generator /usr/local/bin/eth-genesis-state-generator
COPY --from=builder /go/bin/eth2-val-tools /usr/local/bin/eth2-val-tools
COPY --from=builder /go/bin/geth-hdwallet /usr/local/bin/geth-hdwallet

COPY config-example /config
COPY defaults /defaults
COPY entrypoint.sh .
ENTRYPOINT [ "/work/entrypoint.sh" ]
