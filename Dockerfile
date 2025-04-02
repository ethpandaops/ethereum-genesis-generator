FROM golang:1.24 as builder
WORKDIR /work
RUN git clone https://github.com/ethpandaops/eth-beacon-genesis.git  \
    && cd eth-beacon-genesis && make \
    && go install github.com/protolambda/eth2-val-tools@latest

FROM debian:latest
WORKDIR /work
VOLUME ["/config", "/data"]
EXPOSE 8000/tcp
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    ca-certificates build-essential python3 python3-dev python3.11-venv python3-venv python3-pip gettext-base jq wget curl && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY apps /apps

ENV PATH="/root/.cargo/bin:${PATH}"
RUN cd /apps/el-gen && python3 -m venv .venv && /apps/el-gen/.venv/bin/pip3 install -r /apps/el-gen/requirements.txt
COPY --from=builder /work/eth-beacon-genesis/bin/eth-beacon-genesis /usr/local/bin/eth-beacon-genesis
COPY --from=builder /go/bin/eth2-val-tools /usr/local/bin/eth2-val-tools
COPY config-example /config
COPY defaults /defaults
COPY entrypoint.sh .
ENTRYPOINT [ "/work/entrypoint.sh" ]