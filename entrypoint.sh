#!/bin/bash -xe
ETH1_BLOCK="${ETH1_BLOCK:-0x0000000000000000000000000000000000000000000000000000000000000000}"
TIMESTAMP_DELAY_SECONDS="${TIMESTAMP_DELAY_SECONDS:-300}"
NOW=$(date +%s)
TIMESTAMP=$((NOW + TIMESTAMP_DELAY_SECONDS))


gen_el_config(){
    if ! [ -f "/data/el/geth.json" ]; then
        mkdir -p /data/el
        cp /config/el/genesis-config.yaml /apps/el-gen/genesis-config.yaml
        cd /apps/el-gen
        python3 genesis_geth.py      > /data/el/geth.json
        python3 genesis_chainspec.py > /data/el/chainspec.json
    else
        echo "el genesis already exists. skipping generation..."
    fi
}

gen_cl_config(){
    # Consensus layer: Check if genesis already exists
    if ! [ -f "/data/cl/genesis.ssz" ]; then
        mkdir -p /data/cl
        # Replace MIN_GENESIS_TIME on config
        cp /config/cl/config.yaml /data/cl/config.yaml
        sed -i "s/^MIN_GENESIS_TIME:.*/MIN_GENESIS_TIME: ${TIMESTAMP}/" /data/cl/config.yaml
        # Create deposit_contract.txt and deploy_block.txt
        grep DEPOSIT_CONTRACT_ADDRESS /data/cl/config.yaml | cut -d " " -f2 > /data/cl/deposit_contract.txt
        echo "0" > /data/cl/deploy_block.txt
        # Generate genesis
        /usr/local/bin/eth2-testnet-genesis phase0 \
        --config /data/cl/config.yaml \
        --eth1-block "${ETH1_BLOCK}" \
        --mnemonics /config/cl/mnemonics.yaml \
        --timestamp "${TIMESTAMP}" \
        --tranches-dir /data/cl/tranches \
        --state-output /data/cl/genesis.ssz
    else
        echo "cl genesis already exists. skipping generation..."
    fi
}

gen_all_config(){
    gen_el_config
    gen_cl_config
}

case $1 in
  --el)
    gen_el_config
    ;;
  --cl)
    gen_cl_config
    ;;
  *)
    gen_all_config
    ;;
esac

# Start webserver
cd /data && exec python -m SimpleHTTPServer 8000
