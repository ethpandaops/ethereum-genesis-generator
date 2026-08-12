#!/bin/bash -e

# Determine preset early: peek at values.env, fall back to env var, default to mainnet
PRESET_PEEK=$(grep -s "^export PRESET_BASE=" /config/values.env 2>/dev/null | tail -1 | sed 's/export PRESET_BASE=//' | tr -d '"' | tr -d "'" || true)
PRESET_BASE="${PRESET_PEEK:-${PRESET_BASE:-mainnet}}"

# Source preset-specific defaults before mainnet defaults.
# Uses :- syntax so docker env vars take precedence, while defaults.env
# (also :-) won't override values already set here.
if [[ "$PRESET_BASE" == "minimal" ]]; then
    source /defaults/minimal.env
fi

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


# Builds the BLOB_SCHEDULE YAML block from BPO_* env vars and echoes it.
# Emits `BLOB_SCHEDULE: []` when no BPO is non-default.
build_blob_schedule() {
    local include_schedule=false
    local schedule=""
    local default_epoch="18446744073709551615"

    for i in {1..5}; do
        local var_epoch="BPO_${i}_EPOCH"
        local var_blobs="BPO_${i}_MAX_BLOBS"
        local var_next_epoch="BPO_$((i+1))_EPOCH"

        if [ -n "${!var_epoch}" ] && [ "${!var_epoch}" != "$default_epoch" ]; then
            if [ "${!var_next_epoch}" == "${!var_epoch}" ]; then
                echo "BPO $i has the same activation epoch as the followup BPO $((i+1)), skipping for CL config..." >&2
                continue
            fi

            if [ "$include_schedule" = false ]; then
                schedule="BLOB_SCHEDULE:"
                include_schedule=true
            fi

            schedule="$schedule
  - EPOCH: ${!var_epoch}
    MAX_BLOBS_PER_BLOCK: ${!var_blobs}"
        fi
    done

    if [ "$include_schedule" = true ]; then
        echo "$schedule"
    else
        echo "BLOB_SCHEDULE: []"
    fi
}

# Builds the GAS_LIMIT_SCHEDULE YAML block (EIP-8261) from the
# GAS_LIMIT_SCHEDULE env var, a JSON array of GPO entries like:
#   [{"epoch": 256, "gas_limit": 100000000}, ...]
# Emits `GAS_LIMIT_SCHEDULE: []` when the array is empty.
build_gas_limit_schedule() {
    local schedule_json="${GAS_LIMIT_SCHEDULE:-[]}"

    if ! echo "$schedule_json" | jq -e 'type == "array" and all(.[]; (.epoch | type == "number") and (.gas_limit | type == "number"))' > /dev/null; then
        echo "GAS_LIMIT_SCHEDULE must be a JSON array of {\"epoch\": <number>, \"gas_limit\": <number>} entries, got: $schedule_json" >&2
        return 1
    fi

    if [ "$(echo "$schedule_json" | jq 'length')" -eq 0 ]; then
        echo "GAS_LIMIT_SCHEDULE: []"
        return
    fi

    echo "GAS_LIMIT_SCHEDULE:"
    echo "$schedule_json" | jq -r 'sort_by(.epoch) | .[] | "  - EPOCH: \(.epoch)\n    GAS_LIMIT: \(.gas_limit)"'
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

        # Build the BLOB_SCHEDULE and GAS_LIMIT_SCHEDULE blocks and
        # substitute them in place so each section keeps its position
        # in the template.
        export BLOB_SCHEDULE_YAML="$(build_blob_schedule)"
        GAS_LIMIT_SCHEDULE_YAML="$(build_gas_limit_schedule)"
        export GAS_LIMIT_SCHEDULE_YAML
        awk '
            BEGIN {
                blob_section = ENVIRON["BLOB_SCHEDULE_YAML"]
                gas_section = ENVIRON["GAS_LIMIT_SCHEDULE_YAML"]
            }
            /^BLOB_SCHEDULE:/ { print blob_section; in_schedule=1; next }
            /^GAS_LIMIT_SCHEDULE:/ { print gas_section; in_schedule=1; next }
            in_schedule && /^[[:space:]]/ { next }
            { in_schedule=0; print }
        ' /config/cl/config.yaml | sed 's/#HUMAN_TIME_PLACEHOLDER/'"$COMMENT"'/' > $tmp_dir/config_temp.yaml
        # FRAMES_ENABLED=true disables the Heze fork on the CL side only:
        # the CL config gets HEZE_FORK_EPOCH pinned to max uint64, while the
        # EL genesis still activates bogota at the configured HEZE_FORK_EPOCH.
        cl_heze_fork_epoch="$HEZE_FORK_EPOCH"
        if [ "$FRAMES_ENABLED" = "true" ]; then
            cl_heze_fork_epoch="18446744073709551615"
        fi
        HEZE_FORK_EPOCH="$cl_heze_fork_epoch" envsubst < $tmp_dir/config_temp.yaml > /data/metadata/config.yaml

        # Envsubst mnemonics file
        if [ "$WITHDRAWAL_TYPE" == "0x00" ]; then
          export WITHDRAWAL_ADDRESS="null"
        fi
        envsubst < /config/cl/mnemonics.yaml > $tmp_dir/mnemonics.yaml
        if [ -n "$ADDITIONAL_VALIDATOR_MNEMONICS" ] && [ "$ADDITIONAL_VALIDATOR_MNEMONICS" != "[]" ]; then
          echo "Adding additional validator mnemonics..."
          echo "$ADDITIONAL_VALIDATOR_MNEMONICS" | yq --yaml-output >> $tmp_dir/mnemonics.yaml
        fi

        cp $tmp_dir/mnemonics.yaml /data/metadata/mnemonics.yaml
        # Create deposit_contract.txt and deposit_contract_block.txt
        grep DEPOSIT_CONTRACT_ADDRESS /data/metadata/config.yaml | cut -d " " -f2 > /data/metadata/deposit_contract.txt
        echo $CL_EXEC_BLOCK > /data/metadata/deposit_contract_block.txt
        echo $BEACON_STATIC_ENR > /data/metadata/bootstrap_nodes.txt

        # Generate genesis
        genesis_args+=(
          beaconchain
          --config /data/metadata/config.yaml
          --eth1-config /data/metadata/genesis.json
          --mnemonics $tmp_dir/mnemonics.yaml
          --state-output /data/metadata/genesis.ssz
          --json-output /data/parsed/parsedConsensusGenesis.json
          --validators-mapping-output /data/metadata/validator_names.yaml
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

        if [ "$SHUFFLE_VALIDATORS" = "true" ]; then
          genesis_args+=(--shuffle-validators)
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

