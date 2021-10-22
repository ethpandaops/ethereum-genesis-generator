FROM golang:1.17 as builder
RUN go install github.com/protolambda/eth2-testnet-genesis@latest

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
COPY config-example /config
COPY entrypoint.sh .
ENTRYPOINT [ "/app/entrypoint.sh" ]
