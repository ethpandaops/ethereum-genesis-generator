#!/bin/bash -e
export DEFAULT_ENV_FILE="/defaults/defaults.env"
# Load the default env vars into the environment
source $DEFAULT_ENV_FILE

if [ -f /config/values.env ];
then
    # Use user provided env vars if it exists
    export FULL_ENV_FILE="/config/values.env"
    # Pull these values out of the env file since they can be very large and cause
    # "arguments list too long" errors in the shell.
    grep -v "ADDITIONAL_PRELOADED_CONTRACTS" $FULL_ENV_FILE | grep -v "EL_PREMINE_ADDRS" > /tmp/values-short.env
    # print the value of ADDITIONAL_PRELOADED_CONTRACTS
else
    grep -v "ADDITIONAL_PRELOADED_CONTRACTS" $DEFAULT_ENV_FILE | grep -v "EL_PREMINE_ADDRS" > /tmp/values-short.env
fi
# Load the env vars entered by the user without the larger values into the environment
source /tmp/values-short.env


SERVER_ENABLED="${SERVER_ENABLED:-false}"
SERVER_PORT="${SERVER_PORT:-8000}"


gen_shared_files(){
    . /apps/el-gen/.venv/bin/activate
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
    . /apps/el-gen/.venv/bin/activate
    set -x
    if ! [ -f "/data/metadata/genesis.json" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/metadata
        python3 /apps/envsubst.py < /config/el/genesis-config.yaml > $tmp_dir/genesis-config.yaml
        cat $tmp_dir/genesis-config.yaml
        python3 /apps/el-gen/genesis_geth.py $tmp_dir/genesis-config.yaml      > /data/metadata/genesis.json
        python3 /apps/el-gen/genesis_chainspec.py $tmp_dir/genesis-config.yaml > /data/metadata/chainspec.json
        python3 /apps/el-gen/genesis_besu.py $tmp_dir/genesis-config.yaml > /data/metadata/besu.json
    else
        echo "el genesis already exists. skipping generation..."
    fi
}

gen_minimal_config() {
  declare -A replacements=(
    [MIN_PER_EPOCH_CHURN_LIMIT]=2
    [MIN_EPOCHS_FOR_BLOCK_REQUESTS]=272
    [WHISK_EPOCHS_PER_SHUFFLING_PHASE]=4
    [WHISK_PROPOSER_SELECTION_GAP]=1
    [MIN_PER_EPOCH_CHURN_LIMIT_ELECTRA]=64000000000
    [MAX_PER_EPOCH_ACTIVATION_EXIT_CHURN_LIMIT]=128000000000
  )

  for key in "${!replacements[@]}"; do
    sed -i "s/$key:.*/$key: ${replacements[$key]}/" /data/metadata/config.yaml
  done
}

gen_cl_config(){
    . /apps/el-gen/.venv/bin/activate
    set -x
    # Consensus layer: Check if genesis already exists
    if ! [ -f "/data/metadata/genesis.ssz" ]; then
        tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)
        mkdir -p /data/metadata
        mkdir -p /data/parsed
        HUMAN_READABLE_TIMESTAMP=$(date -u -d @"$GENESIS_TIMESTAMP" +"%Y-%b-%d %I:%M:%S %p %Z")
        COMMENT="# $HUMAN_READABLE_TIMESTAMP"
        export MAX_REQUEST_BLOB_SIDECARS_ELECTRA=$(($MAX_REQUEST_BLOCKS_DENEB * $MAX_BLOBS_PER_BLOCK_ELECTRA))
        export MAX_REQUEST_BLOB_SIDECARS_FULU=$(($MAX_REQUEST_BLOCKS_DENEB * $MAX_BLOBS_PER_BLOCK_FULU))
        python3 /apps/envsubst.py < /config/cl/config.yaml > /data/metadata/config.yaml
        sed -i "s/#HUMAN_TIME_PLACEHOLDER/$COMMENT/" /data/metadata/config.yaml
        python3 /apps/envsubst.py < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Conditionally override values if preset is "minimal"
        if [[ "$PRESET_BASE" == "minimal" ]]; then
          gen_minimal_config
        fi
        cp $tmp_dir/mnemonics.yaml /data/metadata/mnemonics.yaml
        # Create deposit_contract.txt and deploy_block.txt
        grep DEPOSIT_CONTRACT_ADDRESS /data/metadata/config.yaml | cut -d " " -f2 > /data/metadata/deposit_contract.txt
        echo $CL_EXEC_BLOCK > /data/metadata/deposit_contract_block.txt
        echo $BEACON_STATIC_ENR > /data/metadata/bootstrap_nodes.txt
        # Envsubst mnemonics
        if [ "$WITHDRAWAL_TYPE" == "0x00" ]; then
          export WITHDRAWAL_ADDRESS="null"
        fi
        python3 /apps/envsubst.py < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        # Generate genesis
        genesis_args+=(
          devnet
          --config /data/metadata/config.yaml
          --eth1-config /data/metadata/genesis.json
          --mnemonics $tmp_dir/mnemonics.yaml
          --state-output /data/metadata/genesis.ssz
          --json-output /data/parsed/parsedConsensusGenesis.json
        )

        if [[ $SHADOW_FORK_FILE != "" ]]; then
          genesis_args+=(--shadow-fork-block-file=$SHADOW_FORK_FILE --eth1-config "")
        elif [[ $SHADOW_FORK_RPC != "" ]]; then
          genesis_args+=(--shadow-fork-eth1-rpc=$SHADOW_FORK_RPC --eth1-config "")
        fi

        if ! [ -z "$CL_ADDITIONAL_VALIDATORS" ]; then
          if [[ $CL_ADDITIONAL_VALIDATORS = /* ]]; then
            validators_file=$CL_ADDITIONAL_VALIDATORS
          else
            validators_file="/config/$CL_ADDITIONAL_VALIDATORS"
          fi
          genesis_args+=(--additional-validators $validators_file)
        fi
        
        /usr/local/bin/eth-beacon-genesis "${genesis_args[@]}"
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

