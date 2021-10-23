#!/bin/bash -xe
ETH1_BLOCK="${ETH1_BLOCK:-0x0000000000000000000000000000000000000000000000000000000000000000}"
TIMESTAMP_DELAY_SECONDS="${TIMESTAMP_DELAY_SECONDS:-300}"
NOW=$(date +%s)
TIMESTAMP=$((NOW + TIMESTAMP_DELAY_SECONDS))

# Check if genesis already exists
if ! [ -f "/data/genesis.ssz" ]; then
    # Replace MIN_GENESIS_TIME on config
    cp /config/config.yaml /data/config.yaml
    sed -i "s/^MIN_GENESIS_TIME:.*/MIN_GENESIS_TIME: ${TIMESTAMP}/" /data/config.yaml
    # Generate genesis
    /usr/local/bin/eth2-testnet-genesis phase0 \
      --config /data/config.yaml \
      --eth1-block "${ETH1_BLOCK}" \
      --mnemonics /config/mnemonics.yaml \
      --timestamp "${TIMESTAMP}" \
      --tranches-dir /data/tranches \
      --state-output /data/genesis.ssz
else
    echo "genesis already exists. skipping generation"
fi

cd /data && exec python -m SimpleHTTPServer 8000
