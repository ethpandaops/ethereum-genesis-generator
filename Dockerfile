FROM golang:1.17 as builder
RUN git clone https://github.com/skylenet/eth2-testnet-genesis.git \
    && cd eth2-testnet-genesis && git checkout faster-validator-creation \
    && go install . \
    && go install github.com/protolambda/eth2-val-tools@latest

FROM debian:latest
ENV TIMESTAMP_DELAY_SECONDS=180
WORKDIR /app
VOLUME ["/config", "/data"]
EXPOSE 8000/tcp
RUN apt-get update && \
    apt-get install --no-install-recommends -y ca-certificates python && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /go/bin/eth2-testnet-genesis /usr/local/bin/eth2-testnet-genesis
COPY --from=builder /go/bin/eth2-val-tools /usr/local/bin/eth2-val-tools
COPY config-example /config
COPY entrypoint.sh .
ENTRYPOINT [ "/app/entrypoint.sh" ]
