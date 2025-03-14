FROM golang:1.22 as builder
RUN git clone https://github.com/protolambda/eth2-testnet-genesis.git  \
    && cd eth2-testnet-genesis \
    && go install . \
    && go install github.com/protolambda/eth2-val-tools@latest \
    && go install github.com/protolambda/zcli@latest \
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

COPY --from=builder /go/bin/eth2-testnet-genesis /usr/local/bin/eth2-testnet-genesis
COPY --from=builder /go/bin/eth2-val-tools /usr/local/bin/eth2-val-tools
COPY --from=builder /go/bin/zcli /usr/local/bin/zcli
COPY --from=builder /go/bin/geth-hdwallet /usr/local/bin/geth-hdwallet

COPY config-example /config
COPY defaults /defaults
COPY entrypoint.sh .
ENTRYPOINT [ "/work/entrypoint.sh" ]