#!/bin/bash -e
CL_ETH1_BLOCK="${CL_ETH1_BLOCK:-0x0000000000000000000000000000000000000000000000000000000000000000}"
CL_TIMESTAMP_DELAY_SECONDS="${CL_TIMESTAMP_DELAY_SECONDS:-300}"
CL_FORK="${CL_FORK:-phase0}"
SERVER_PORT="${SERVER_PORT:-8000}"
NOW=$(date +%s)
CL_TIMESTAMP=$((NOW + CL_TIMESTAMP_DELAY_SECONDS))

gen_jwt_secret(){
    set -x
    if ! [ -f "/data/el/jwtsecret" ] || [ -f "/data/cl/jwtsecret" ]; then
        mkdir -p /data/el
        echo -n 0x$(openssl rand -hex 32 | tr -d "\n") > /data/el/jwtsecret
        cp /data/el/jwtsecret /data/cl/jwtsecret
    else
        echo "JWT secret already exists. skipping generation..."
    fi
}

gen_el_config(){
    set -x
    if ! [ -f "/data/el/geth.json" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/el
        envsubst < /config/el/genesis-config.yaml > $tmp_dir/genesis-config.yaml
        python3 /apps/el-gen/genesis_geth.py $tmp_dir/genesis-config.yaml      > /data/el/geth.json
        python3 /apps/el-gen/genesis_chainspec.py $tmp_dir/genesis-config.yaml > /data/el/chainspec.json
        python3 /apps/el-gen/genesis_besu.py $tmp_dir/genesis-config.yaml > /data/el/besu.json
    else
        echo "el genesis already exists. skipping generation..."
    fi
}

gen_cl_config(){
    set -x
    # Consensus layer: Check if genesis already exists
    if ! [ -f "/data/cl/genesis.ssz" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/cl
        # Replace environment vars in files
        envsubst < /config/cl/config.yaml > /data/cl/config.yaml
        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Replace MIN_GENESIS_TIME on config
        sed "s/^MIN_GENESIS_TIME:.*/MIN_GENESIS_TIME: ${CL_TIMESTAMP}/" /data/cl/config.yaml > /tmp/config.yaml
	    mv /tmp/config.yaml /data/cl/config.yaml
        # Create deposit_contract.txt and deploy_block.txt
        grep DEPOSIT_CONTRACT_ADDRESS /data/cl/config.yaml | cut -d " " -f2 > /data/cl/deposit_contract.txt
        echo "0" > /data/cl/deploy_block.txt
        # Envsubst mnemonics
        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Generate genesis
        /usr/local/bin/eth2-testnet-genesis $CL_FORK \
        --config /data/cl/config.yaml \
        --eth1-block "${CL_ETH1_BLOCK}" \
        --mnemonics $tmp_dir/mnemonics.yaml \
        --timestamp "${CL_TIMESTAMP}" \
        --tranches-dir /data/cl/tranches \
        --state-output /data/cl/genesis.ssz
    else
        echo "cl genesis already exists. skipping generation..."
    fi
}

gen_all_config(){
    gen_el_config
    gen_cl_config
    gen_jwt_secret
}

case $1 in
  el)
    gen_el_config
    ;;
  cl)
    gen_cl_config
    ;;
  all)
    gen_all_config
    ;;
  *)
    set +x
    echo "Usage: [all|cl|el]"
    exit 1
    ;;
esac

# Start webserver
cd /data && exec python -m SimpleHTTPServer "$SERVER_PORT"
