#!/bin/bash -e

# Load the default env vars into the environment
source /defaults/defaults.env

# Load the env vars entered by the user
if [ -f /config/values.env ];
then
    source /config/values.env
fi


SERVER_ENABLED="${SERVER_ENABLED:-false}"
SERVER_PORT="${SERVER_PORT:-8000}"


gen_shared_files(){
    set -x
    # Shared files
    mkdir -p /data/metadata
    if ! [ -f "/data/jwt/jwtsecret" ]; then
        mkdir -p /data/jwt
        echo -n 0x$(openssl rand -hex 32 | tr -d "\n") > /data/jwt/jwtsecret
    fi
    if [ -f "/data/metadata/genesis.json" ]; then
        terminalTotalDifficulty=$(cat /data/metadata/genesis.json | jq -r '.config.terminalTotalDifficulty | tostring')
        sed -i "s/TERMINAL_TOTAL_DIFFICULTY:.*/TERMINAL_TOTAL_DIFFICULTY: $terminalTotalDifficulty/" /data/metadata/config.yaml
    fi
}

gen_el_config(){
    set -x
    if ! [ -f "/data/metadata/genesis.json" ]; then
        mkdir -p /data/metadata
        source /apps/el-gen/generate_genesis.sh
        generate_genesis /data/metadata
    else
        echo "el genesis already exists. skipping generation..."
    fi
}

gen_minimal_config() {
  declare -A replacements=(
    [MIN_PER_EPOCH_CHURN_LIMIT]=2
    [MIN_EPOCHS_FOR_BLOCK_REQUESTS]=272
    [MIN_PER_EPOCH_CHURN_LIMIT_ELECTRA]=64000000000
    [MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT]=128000000000
    # EIP7441
    [EPOCHS_PER_SHUFFLING_PHASE]=4
    [PROPOSER_SELECTION_GAP]=1
  )

  for key in "${!replacements[@]}"; do
    sed -i "s/$key:.*/$key: ${replacements[$key]}/" /data/metadata/config.yaml
  done
}

# This function conditionally adds the BLOB_SCHEDULE section to the config.yaml file
# It only adds the section if any BPO is non-default
add_blob_schedule() {
    # Takes config file path as argument
    local config_file=$1

    # Check if any BPO is non-default and build BLOB_SCHEDULE if needed
    INCLUDE_SCHEDULE=false
    BLOB_SCHEDULE=""

    # The default value is already in the environment from defaults.env
    DEFAULT_BPO_EPOCH="18446744073709551615"

    for i in {1..5}; do
        var_epoch="BPO_${i}_EPOCH"
        var_blobs="BPO_${i}_MAX_BLOBS"

        # Check if this BPO has a non-default value
        if [ -n "${!var_epoch}" ] && [ "${!var_epoch}" != "$DEFAULT_BPO_EPOCH" ]; then
            if [ "$INCLUDE_SCHEDULE" = false ]; then
                # First non-default BPO - add header
                BLOB_SCHEDULE="
BLOB_SCHEDULE:"
                INCLUDE_SCHEDULE=true
            fi

            # Add this BPO entry
            BLOB_SCHEDULE="$BLOB_SCHEDULE
  - EPOCH: ${!var_epoch}
    MAX_BLOBS_PER_BLOCK: ${!var_blobs}"
        fi
    done

    # Append BLOB_SCHEDULE section
    if [ "$INCLUDE_SCHEDULE" = true ]; then
        echo "$BLOB_SCHEDULE" >> "$config_file"
    else
        # Add empty BLOB_SCHEDULE if no non-default BPOs were found
        echo "
BLOB_SCHEDULE: []" >> "$config_file"
    fi
}

gen_cl_config(){
    set -x
    # Consensus layer: Check if genesis already exists
    if ! [ -f "/data/metadata/genesis.ssz" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/metadata
        mkdir -p /data/parsed
        HUMAN_READABLE_TIMESTAMP=$(date -u -d @"$GENESIS_TIMESTAMP" +"%Y-%b-%d %I:%M:%S %p %Z")
        COMMENT="# $HUMAN_READABLE_TIMESTAMP"
        export MAX_REQUEST_BLOB_SIDECARS_ELECTRA=$(($MAX_REQUEST_BLOCKS_DENEB * $MAX_BLOBS_PER_BLOCK_ELECTRA))

        # Process main config file without BLOB_SCHEDULE
        cat /config/cl/config.yaml | sed '/^BLOB_SCHEDULE:/,/^[a-zA-Z]/ d' | sed 's/#HUMAN_TIME_PLACEHOLDER/'"$COMMENT"'/' > $tmp_dir/config_temp.yaml
        envsubst < $tmp_dir/config_temp.yaml > /data/metadata/config.yaml

        # Add BLOB_SCHEDULE if needed
        add_blob_schedule /data/metadata/config.yaml

        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Conditionally override values if preset is "minimal"
        if [[ "$PRESET_BASE" == "minimal" ]]; then
          gen_minimal_config
        fi
        cp $tmp_dir/mnemonics.yaml /data/metadata/mnemonics.yaml
        # Create deposit_contract.txt and deposit_contract_block.txt
        grep DEPOSIT_CONTRACT_ADDRESS /data/metadata/config.yaml | cut -d " " -f2 > /data/metadata/deposit_contract.txt
        echo $CL_EXEC_BLOCK > /data/metadata/deposit_contract_block.txt
        echo $BEACON_STATIC_ENR > /data/metadata/bootstrap_nodes.txt
        # Envsubst mnemonics
        if [ "$WITHDRAWAL_TYPE" == "0x00" ]; then
          export WITHDRAWAL_ADDRESS="null"
        fi
        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Generate genesis
        genesis_args+=(
          beaconchain
          --config /data/metadata/config.yaml
          --eth1-config /data/metadata/genesis.json
          --mnemonics $tmp_dir/mnemonics.yaml
          --state-output /data/metadata/genesis.ssz
          --json-output /data/parsed/parsedConsensusGenesis.json
        )

        if [[ $SHADOW_FORK_FILE != "" ]]; then
          genesis_args+=(--shadow-fork-block=$SHADOW_FORK_FILE)
        elif [[ $SHADOW_FORK_RPC != "" ]]; then
          genesis_args+=(--shadow-fork-rpc=$SHADOW_FORK_RPC)
        fi

        if ! [ -z "$CL_ADDITIONAL_VALIDATORS" ]; then
          if [[ $CL_ADDITIONAL_VALIDATORS = /* ]]; then
            validators_file=$CL_ADDITIONAL_VALIDATORS
          else
            validators_file="/config/$CL_ADDITIONAL_VALIDATORS"
          fi
          genesis_args+=(--additional-validators $validators_file)
        fi

        /usr/local/bin/eth-genesis-state-generator "${genesis_args[@]}"
        echo "Genesis args: ${genesis_args[@]}"
        echo "Genesis block number: $(jq -r '.latest_execution_payload_header.block_number' /data/parsed/parsedConsensusGenesis.json)"
        echo "Genesis block hash: $(jq -r '.latest_execution_payload_header.block_hash' /data/parsed/parsedConsensusGenesis.json)"
        jq -r '.eth1_data.block_hash' /data/parsed/parsedConsensusGenesis.json| tr -d '\n' > /data/metadata/deposit_contract_block_hash.txt
        jq -r '.genesis_validators_root' /data/parsed/parsedConsensusGenesis.json | tr -d '\n' > /data/metadata/genesis_validators_root.txt
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

