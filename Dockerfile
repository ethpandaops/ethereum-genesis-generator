FROM golang:1.17 as builder
RUN git clone https://github.com/skylenet/eth2-testnet-genesis.git \
    && cd eth2-testnet-genesis && git checkout faster-validator-creation \
    && go install . \
    && go install github.com/protolambda/eth2-val-tools@latest

FROM debian:latest
WORKDIR /work
VOLUME ["/config", "/data"]
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
        ca-certificates build-essential python python3-dev python3-pip gettext-base && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
COPY apps /apps
RUN cd /apps/el-gen && pip3 install -r requirements.txt
COPY --from=builder /go/bin/eth2-testnet-genesis /usr/local/bin/eth2-testnet-genesis
COPY --from=builder /go/bin/eth2-val-tools /usr/local/bin/eth2-val-tools
COPY config-example /config
COPY generate-genesis.sh .

# We expect the user to 'docker exec' the generate-genesis.sh script
ENTRYPOINT [ "sleep", "999999"]
