#!/bin/bash -e
source /config/values.env
SERVER_PORT="${SERVER_PORT:-8000}"
WITHDRAWAL_ADDRESS="${WITHDRAWAL_ADDRESS:-0xf97e180c050e5Ab072211Ad2C213Eb5AEE4DF134}"

gen_shared_files(){
    set -x
    # Shared files
    mkdir -p /data/custom_config_data
    cp /apps/trusted_setup.txt /data/custom_config_data/trusted_setup.txt
    if ! [ -f "/data/el/jwtsecret" ] || [ -f "/data/cl/jwtsecret" ]; then
        mkdir -p /data/el
        mkdir -p /data/cl
        echo -n 0x$(openssl rand -hex 32 | tr -d "\n") > /data/el/jwtsecret
        cp /data/el/jwtsecret /data/cl/jwtsecret
    else
        echo "JWT secret already exists. skipping generation..."
    fi
}

gen_el_config(){
    set -x
    if ! [ -f "/data/custom_config_data/genesis.json" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/custom_config_data
        envsubst < /config/el/genesis-config.yaml > $tmp_dir/genesis-config.yaml
        python3 /apps/el-gen/genesis_geth.py $tmp_dir/genesis-config.yaml      > /data/custom_config_data/genesis.json
        python3 /apps/el-gen/genesis_chainspec.py $tmp_dir/genesis-config.yaml > /data/custom_config_data/chainspec.json
        python3 /apps/el-gen/genesis_besu.py $tmp_dir/genesis-config.yaml > /data/custom_config_data/besu.json
    else
        echo "el genesis already exists. skipping generation..."
    fi
}

gen_cl_config(){
    set -x
    # Consensus layer: Check if genesis already exists
    if ! [ -f "/data/custom_config_data/genesis.ssz" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/custom_config_data
        # Replace environment vars in files
        envsubst < /config/cl/config.yaml > /data/custom_config_data/config.yaml
        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        cp $tmp_dir/mnemonics.yaml /data/custom_config_data/mnemonics.yaml
        # Create deposit_contract.txt and deploy_block.txt
        grep DEPOSIT_CONTRACT_ADDRESS /data/custom_config_data/config.yaml | cut -d " " -f2 > /data/custom_config_data/deposit_contract.txt
        echo $CL_EXEC_BLOCK > /data/custom_config_data/deploy_block.txt
        echo $CL_EXEC_BLOCK > /data/custom_config_data/deposit_contract_block.txt
        echo $BEACON_STATIC_ENR > /data/custom_config_data/bootstrap_nodes.txt
        echo "- $BEACON_STATIC_ENR" > /data/custom_config_data/boot_enr.txt
        # Envsubst mnemonics
        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Generate genesis
        genesis_args=(
          bellatrix
          --config /data/custom_config_data/config.yaml
          --mnemonics $tmp_dir/mnemonics.yaml
          --tranches-dir /data/custom_config_data/tranches
          --state-output /data/custom_config_data/genesis.ssz
        )
        if [[ $WITHDRAWAL_TYPE == "0x01" ]]; then
          genesis_args+=(--eth1-withdrawal-address $WITHDRAWAL_ADDRESS)
        fi
        if [[ $SHADOW_FORK_RPC != "" ]]; then
          genesis_args+=(--shadow-fork-eth1-rpc=$SHADOW_FORK_RPC --eth1-config "")
        else
          genesis_args+=(--eth1-config /data/custom_config_data/genesis.json)
        fi
        /usr/local/bin/eth2-testnet-genesis "${genesis_args[@]}"
        /usr/local/bin/zcli pretty bellatrix BeaconState /data/custom_config_data/genesis.ssz > /data/custom_config_data/parsedBeaconState.json
        jq -r '.eth1_data.block_hash' /data/custom_config_data/parsedBeaconState.json > /data/custom_config_data/deposit_contract_block_hash.txt
    else
        echo "cl genesis already exists. skipping generation..."
    fi
}

gen_all_config(){
    gen_el_config
    gen_cl_config
    gen_shared_files
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
