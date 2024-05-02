#!/bin/bash -e
source /config/values.env
SERVER_ENABLED="${SERVER_ENABLED:-false}"
SERVER_PORT="${SERVER_PORT:-8000}"
WITHDRAWAL_ADDRESS="${WITHDRAWAL_ADDRESS:-0xf97e180c050e5Ab072211Ad2C213Eb5AEE4DF134}"
PRESET_BASE="${PRESET_BASE:-mainnet}"
gen_shared_files(){
    . /apps/el-gen/.venv/bin/activate
    set -x
    # Shared files
    mkdir -p /data/custom_config_data
    if ! [ -f "/data/jwt/jwtsecret" ]; then
        mkdir -p /data/jwt
        echo -n 0x$(openssl rand -hex 32 | tr -d "\n") > /data/jwt/jwtsecret
    fi
    if [ -f "/data/custom_config_data/genesis.json" ]; then
        terminalTotalDifficulty=$(cat /data/custom_config_data/genesis.json | jq -r '.config.terminalTotalDifficulty | tostring')
        sed -i "s/TERMINAL_TOTAL_DIFFICULTY:.*/TERMINAL_TOTAL_DIFFICULTY: $terminalTotalDifficulty/" /data/custom_config_data/config.yaml
    fi
}

gen_el_config(){
    . /apps/el-gen/.venv/bin/activate
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

gen_minimal_config() {
  declare -A replacements=(
    [MIN_PER_EPOCH_CHURN_LIMIT]=2
    [CHURN_LIMIT_QUOTIENT]=32
    [MIN_EPOCHS_FOR_BLOCK_REQUESTS]=272
    [WHISK_EPOCHS_PER_SHUFFLING_PHASE]=4
    [WHISK_PROPOSER_SELECTION_GAP]=1
    [MIN_PER_EPOCH_CHURN_LIMIT_ELECTRA]=64000000000
    [MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT]=128000000000
  )

  for key in "${!replacements[@]}"; do
    sed -i "s/$key:.*/$key: ${replacements[$key]}/" /data/custom_config_data/config.yaml
  done
}

gen_cl_config(){
    . /apps/el-gen/.venv/bin/activate
    set -x
    # Consensus layer: Check if genesis already exists
    if ! [ -f "/data/custom_config_data/genesis.ssz" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/custom_config_data
        envsubst < /config/cl/config.yaml > /data/custom_config_data/config.yaml
        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Conditionally override values if preset is "minimal"
        if [[ "$PRESET_BASE" == "minimal" ]]; then
          gen_minimal_config
        fi
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
          deneb
          --config /data/custom_config_data/config.yaml
          --mnemonics $tmp_dir/mnemonics.yaml
          --tranches-dir /data/custom_config_data/tranches
          --state-output /data/custom_config_data/genesis.ssz
          --preset-phase0 $PRESET_BASE
          --preset-altair $PRESET_BASE
          --preset-bellatrix $PRESET_BASE
          --preset-capella $PRESET_BASE
          --preset-deneb $PRESET_BASE
        )
        if [[ $WITHDRAWAL_TYPE == "0x01" ]]; then
          genesis_args+=(--eth1-withdrawal-address $WITHDRAWAL_ADDRESS)
        fi
        if [[ $SHADOW_FORK_FILE != "" ]]; then
          genesis_args+=(--shadow-fork-block-file=$SHADOW_FORK_FILE --eth1-config "")
        elif [[ $SHADOW_FORK_RPC != "" ]]; then
          genesis_args+=(--shadow-fork-eth1-rpc=$SHADOW_FORK_RPC --eth1-config "")
        else
          genesis_args+=(--eth1-config /data/custom_config_data/genesis.json)
        fi
        if ! [ -z "$CL_ADDITIONAL_VALIDATORS" ]; then
          if [[ $CL_ADDITIONAL_VALIDATORS = /* ]]; then
            validators_file=$CL_ADDITIONAL_VALIDATORS
          else
            validators_file="/config/$CL_ADDITIONAL_VALIDATORS"
          fi
          genesis_args+=(--additional-validators $validators_file)
        fi
        zcli_args=(
          pretty
          deneb
          BeaconState
          --preset-phase0 $PRESET_BASE
          --preset-altair $PRESET_BASE
          --preset-bellatrix $PRESET_BASE
          --preset-capella $PRESET_BASE
          --preset-deneb $PRESET_BASE
          /data/custom_config_data/genesis.ssz
        )
        /usr/local/bin/eth2-testnet-genesis "${genesis_args[@]}"
        /usr/local/bin/zcli "${zcli_args[@]}" > /data/custom_config_data/parsedBeaconState.json
        echo "Genesis args: ${genesis_args[@]}"
        echo "Genesis block number: $(jq -r '.latest_execution_payload_header.block_number' /data/custom_config_data/parsedBeaconState.json)"
        echo "Genesis block hash: $(jq -r '.latest_execution_payload_header.block_hash' /data/custom_config_data/parsedBeaconState.json)"
        jq -r '.eth1_data.block_hash' /data/custom_config_data/parsedBeaconState.json | tr -d '\n' > /data/custom_config_data/deposit_contract_block_hash.txt
        jq -r '.genesis_validators_root' /data/custom_config_data/parsedBeaconState.json | tr -d '\n' > /data/custom_config_data/genesis_validators_root.txt
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
if [ "$SERVER_ENABLED" = true ] ; then
  cd /data && exec python3 -m http.server "$SERVER_PORT"
fi
