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

# Schedules a BPO and a GAS_LIMIT_SCHEDULE entry at HEZE_FORK_EPOCH scaled by
# SLOT_DURATION_MS_HEZE / SLOT_DURATION_MS, unless one is already set there.
schedule_heze_slot_duration_scaling() {
    local far_future="18446744073709551615"
    local old_ms="$SLOT_DURATION_MS"
    local new_ms="$SLOT_DURATION_MS_HEZE"
    local heze="$HEZE_FORK_EPOCH"

    if [ "$new_ms" == "$old_ms" ] || [ "$heze" == "0" ] || [ "$heze" == "$far_future" ] || [ "$FRAMES_ENABLED" == "true" ]; then
        return
    fi

    schedule_heze_slot_duration_bpo "$far_future" "$old_ms" "$new_ms" "$heze"
    if [ "$GLOAS_FORK_EPOCH" != "$far_future" ]; then
        schedule_heze_slot_duration_gas_limit "$old_ms" "$new_ms" "$heze"
    fi
}

schedule_heze_slot_duration_bpo() {
    local far_future=$1 old_ms=$2 new_ms=$3 heze=$4
    local bpos=()

    for i in {1..5}; do
        local var_epoch="BPO_${i}_EPOCH"
        local var_target="BPO_${i}_TARGET_BLOBS"
        local var_max="BPO_${i}_MAX_BLOBS"
        local var_fraction="BPO_${i}_BASE_FEE_UPDATE_FRACTION"
        [ "${!var_epoch}" == "$heze" ] && return
        if [ -n "${!var_epoch}" ] && [ "${!var_epoch}" != "$far_future" ]; then
            bpos+=("${!var_epoch} ${!var_target} ${!var_max} ${!var_fraction:-0}")
        fi
    done

    if [ "${#bpos[@]}" -eq 5 ]; then
        echo "WARNING: SLOT_DURATION_MS_HEZE ($new_ms) differs from SLOT_DURATION_MS ($old_ms) but all BPOs are in use, so no BPO is scheduled at HEZE_FORK_EPOCH ($heze)" >&2
        return
    fi

    local prev_target="$TARGET_BLOBS_PER_BLOCK_ELECTRA"
    local prev_max="$MAX_BLOBS_PER_BLOCK_ELECTRA"
    local prev_fraction="$BASEFEE_UPDATE_FRACTION_ELECTRA"
    local sorted=()
    mapfile -t sorted < <(printf '%s\n' "${bpos[@]}" | sort -s -n -k1,1)
    for bpo in "${sorted[@]}"; do
        read -r epoch target max fraction <<< "$bpo"
        if [ "$epoch" -lt "$heze" ]; then
            prev_target=$target
            prev_max=$max
            prev_fraction=$fraction
        fi
    done
    if [ "$prev_fraction" == "0" ]; then
        prev_fraction=$(awk -v m="$prev_max" 'BEGIN { printf "%d", m * 131072 / 0.23556607131276688 + 0.5 }')
    fi

    local new_target=$(( (2 * prev_target * new_ms + old_ms) / (2 * old_ms) ))
    [ "$new_target" -lt 1 ] && new_target=1
    local new_max=$(( (2 * prev_max * new_target + prev_target) / (2 * prev_target) ))
    local new_fraction=$(( (2 * prev_fraction * new_target * old_ms + prev_target * new_ms) / (2 * prev_target * new_ms) ))

    mapfile -t sorted < <(printf '%s\n' "${bpos[@]}" "$heze $new_target $new_max $new_fraction" | sort -s -n -k1,1)
    local i=1
    for bpo in "${sorted[@]}"; do
        read -r epoch target max fraction <<< "$bpo"
        export BPO_${i}_EPOCH="$epoch" BPO_${i}_TARGET_BLOBS="$target" BPO_${i}_MAX_BLOBS="$max" BPO_${i}_BASE_FEE_UPDATE_FRACTION="$fraction"
        i=$((i + 1))
    done
    for ((; i<=5; i++)); do
        export BPO_${i}_EPOCH="$far_future"
    done

    echo "Scheduled a BPO at HEZE_FORK_EPOCH $heze for ${old_ms}ms -> ${new_ms}ms slots: target $prev_target -> $new_target, max $prev_max -> $new_max, base fee update fraction $prev_fraction -> $new_fraction" >&2
}

schedule_heze_slot_duration_gas_limit() {
    local old_ms=$1 new_ms=$2 heze=$3
    local schedule="${GAS_LIMIT_SCHEDULE:-[]}"

    if [ "$(echo "$schedule" | jq --argjson e "$heze" 'any(.[]; .epoch == $e)')" == "true" ]; then
        return
    fi

    local prev
    prev=$(echo "$schedule" | jq --argjson e "$heze" '[.[] | select(.epoch < $e)] | sort_by(.epoch) | last | .gas_limit // empty')
    if [ -z "$prev" ]; then
        prev="$GENESIS_GASLIMIT"
        if [ "$GLOAS_FORK_EPOCH" -lt "$heze" ]; then
            schedule=$(echo "$schedule" | jq -c --argjson e "$GLOAS_FORK_EPOCH" --argjson g "$prev" '. + [{"epoch": $e, "gas_limit": $g}]')
        fi
    fi

    local gas_limit=$(( (2 * prev * new_ms + old_ms) / (2 * old_ms) ))
    GAS_LIMIT_SCHEDULE=$(echo "$schedule" | jq -c --argjson e "$heze" --argjson g "$gas_limit" '. + [{"epoch": $e, "gas_limit": $g}] | sort_by(.epoch)')
    export GAS_LIMIT_SCHEDULE

    echo "Scheduled gas limit $prev -> $gas_limit at HEZE_FORK_EPOCH $heze for ${old_ms}ms -> ${new_ms}ms slots" >&2
}

schedule_heze_slot_duration_scaling

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
#   [{"epoch": 0, "gas_limit": 60000000}, {"epoch": 256, "gas_limit": 100000000}, ...]
# Emits `GAS_LIMIT_SCHEDULE: []` when the array is empty.
build_gas_limit_schedule() {
    local schedule_json="${GAS_LIMIT_SCHEDULE:-[]}"

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

