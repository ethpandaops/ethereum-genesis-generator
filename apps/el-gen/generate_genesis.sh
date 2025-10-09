#!/bin/bash

# Main function that generates ethereum execution layer genesis configuration files
# Creates genesis.json, chainspec.json, and besu.json for different EL clients
# Supports both new networks and shadowforks of existing networks
# Args:
#   $1: Output directory for generated genesis files
generate_genesis() {
    set +x
    export CHAIN_ID_HEX="0x$(printf "%x" $CHAIN_ID)"
    export GENESIS_TIMESTAMP_HEX="0x$(printf "%x" $GENESIS_TIMESTAMP)"
    export GENESIS_GASLIMIT_HEX="0x$(printf "%x" $GENESIS_GASLIMIT)"
    export GENESIS_DIFFICULTY_HEX="0x$(printf "%x" $GENESIS_DIFFICULTY)"

    # settings
    max_bpos=5
    
    # variables
    is_shadowfork="1"
    has_fork="0"
    has_bpos="0"
    shadowfork_cutoff_time="0"
    shadowfork_blob_schedule=""

    # output directory
    local out_dir=$1
    local tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)

    # has_fork tracks the fork version of the input genesis
    # 0 - phase0
    # 1 - altair
    # 2 - bellatrix / merge
    # 3 - capella / shanghai
    # 4 - deneb / cancun
    # 5 - electra / prague
    # 6 - fulu / osaka
    # 7 - gloas / amsterdam
    # 8 - eip7805 / eip7805

    if [ "$CHAIN_ID" == "1" ]; then
        # mainnet shadowfork
        genesis_load_base_genesis "mainnet" "$tmp_dir"
    elif [ "$CHAIN_ID" == "11155111" ]; then
        # sepolia shadowfork
        genesis_load_base_genesis "sepolia" "$tmp_dir"
    elif [ "$CHAIN_ID" == "17000" ]; then
        # holesky shadowfork
        genesis_load_base_genesis "holesky" "$tmp_dir"
    elif [ "$CHAIN_ID" == "560048" ]; then
        # hoodi shadowfork
        genesis_load_base_genesis "hoodi" "$tmp_dir"
    else
        # Generate base genesis.json, chainspec.json and besu.json
        envsubst < /apps/el-gen/tpl-genesis.json   > $tmp_dir/genesis.json
        envsubst < /apps/el-gen/tpl-chainspec.json > $tmp_dir/chainspec.json
        envsubst < /apps/el-gen/tpl-besu.json      > $tmp_dir/besu.json
        is_shadowfork="0"
    fi

    if [ "$is_shadowfork" == "1" ]; then
        echo "Shadowfork summary:"
        echo "  Shadowfork cutoff time: $shadowfork_cutoff_time"
        echo "  Latest active fork: $has_fork"
        echo "  Latest active BPO:  $has_bpos"
    fi

    echo "[]" > $tmp_dir/blob_schedule.json

    # Add additional fork properties
    [ $has_fork -lt 2 ] && genesis_add_bellatrix $tmp_dir
    [ $has_fork -lt 3 ] && [ ! "$CAPELLA_FORK_EPOCH"   == "18446744073709551615" ] && genesis_add_capella $tmp_dir
    [ $has_fork -lt 4 ] && [ ! "$DENEB_FORK_EPOCH"     == "18446744073709551615" ] && genesis_add_deneb $tmp_dir
    [ $has_fork -lt 5 ] && [ ! "$ELECTRA_FORK_EPOCH"   == "18446744073709551615" ] && genesis_add_electra $tmp_dir
    [ $has_fork -lt 6 ] && [ ! "$FULU_FORK_EPOCH"      == "18446744073709551615" ] && genesis_add_fulu $tmp_dir
                           [ ! "$FULU_FORK_EPOCH"      == "18446744073709551615" ] && genesis_add_bpos $tmp_dir 1 $max_bpos
    [ $has_fork -lt 7 ] && [ ! "$GLOAS_FORK_EPOCH"     == "18446744073709551615" ] && genesis_add_gloas $tmp_dir
    [ $has_fork -lt 8 ] && [ ! "$EIP7805_FORK_EPOCH"   == "18446744073709551615" ] && genesis_add_eip7805 $tmp_dir

    # apply special chainspec blob schedule format
    genesis_apply_blob_schedule $tmp_dir

    if [ "$is_shadowfork" == "0" ]; then
        # Initialize allocations with precompiles
        echo "Adding precompile allocations..."
        cat /apps/el-gen/precompile-allocs.yaml | yq -c > $tmp_dir/allocations.json

        # Add system contracts
        genesis_add_system_contracts $tmp_dir

        # Build complete allocations object before applying
        if [ -f /config/el/genesis-config.yaml ]; then
            envsubst < /config/el/genesis-config.yaml | yq -c > $tmp_dir/el-genesis-config.json

            el_mnemonic=$(jq -r '.mnemonic // env.EL_AND_CL_MNEMONIC' $tmp_dir/el-genesis-config.json)

            # Process all premine wallets in one pass
            echo "Adding premine wallets from mnemonic..."
            jq -c '.el_premine | to_entries[]' $tmp_dir/el-genesis-config.json | while read premine; do
                path=$(echo $premine | jq -r '.key')
                address=$(geth-hdwallet -mnemonic "$el_mnemonic" -path "$path" | grep "public address:" | awk '{print $3}')
                echo "  adding allocation for $address"
                echo "$premine" | jq -c '.value |= gsub(" *ETH"; "000000000000000000") | {"'"$address"'":{"balance":.value}}' >> $tmp_dir/allocations.json
            done

            # Process static premine addresses
            echo "Adding static premine wallets..."
            cat $tmp_dir/el-genesis-config.json | jq -c '.el_premine_addrs
                | with_entries(.value = (if (.value|type) == "string" then {"balance": .value} else .value end))
                | with_entries(.value.balance |= gsub(" *ETH"; "000000000000000000"))
            ' >> $tmp_dir/allocations.json

            # Process additional contracts
            additional_contracts=$(cat $tmp_dir/el-genesis-config.json | jq -cr '.additional_preloaded_contracts')
            if ! [[ "$(echo "$additional_contracts" | sed -e 's/^[[:space:]]*//')" == {* ]]; then
                echo "Additional contracts file: $additional_contracts"
                if [[ "$additional_contracts" =~ ^https?:// ]]; then
                    additional_contracts=$(wget -qO- "$additional_contracts")
                elif [ -f "$additional_contracts" ]; then
                    additional_contracts=$(cat $additional_contracts)
                    if [[ "$additional_contracts" =~ ^https?:// ]]; then
                        additional_contracts=$(wget -qO- "$additional_contracts")
                    fi
                else
                    echo "Additional contracts file not found: $additional_contracts"
                    additional_contracts="{}"
                fi
            fi

            # Add additional contracts to allocations
            echo "Adding additional contracts..."
            echo "$additional_contracts" | jq -c 'with_entries(.value.balance |= gsub(" *ETH"; "000000000000000000"))' >> $tmp_dir/allocations.json
        fi

        # Apply combined allocations in one shot
        echo "Applying allocations to genesis files..."
        allocations=$(jq -s 'reduce .[] as $item ({}; . * $item)' $tmp_dir/allocations.json)
        genesis_add_big_json $tmp_dir/genesis.json "$allocations" '.alloc += $input[0]'
        genesis_add_big_json $tmp_dir/chainspec.json "$allocations" '.accounts += $input[0]'
        genesis_add_big_json $tmp_dir/besu.json "$allocations" '.alloc += $input[0]'
    fi

    cat $tmp_dir/genesis.json   | jq > $out_dir/genesis.json
    cat $tmp_dir/chainspec.json | jq > $out_dir/chainspec.json
    cat $tmp_dir/besu.json      | jq > $out_dir/besu.json
    rm -rf $tmp_dir
}

# Loads base genesis configuration from an existing network for shadowfork creation
# Downloads genesis files from eth-clients repository and determines the latest active fork
# Args:
#   $1: Network name (mainnet, sepolia, holesky, hoodi)
#   $2: Temporary directory to store downloaded files
# Sets global variables:
#   has_fork: Latest active fork number
#   has_bpos: Latest active BPO number
#   shadowfork_cutoff_time: Timestamp for shadowfork cutoff
#   shadowfork_blob_schedule: Latest active blob schedule
genesis_load_base_genesis() {
    local network_name=$1
    local tmp_dir=$2

    # Download genesis files from base network
    wget -O $tmp_dir/genesis.json https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/genesis.json
    wget -O $tmp_dir/chainspec.json https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/chainspec.json
    wget -O $tmp_dir/besu.json https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/besu.json

    # Validate deposit contract address matches base network
    local base_deposit_contract=$(wget -qO- https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/deposit_contract.txt)
    if [ "$DEPOSIT_CONTRACT_ADDRESS" != "$base_deposit_contract" ]; then
        echo "ERROR: DEPOSIT_CONTRACT_ADDRESS ($DEPOSIT_CONTRACT_ADDRESS) must match $network_name ($base_deposit_contract) for shadowfork"
        #exit 1
    fi

    # Get parent network cutoff time
    local block_json
    if [[ $SHADOW_FORK_RPC != "" ]]; then
        local block_number_hex=$(curl -s -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            "$SHADOW_FORK_RPC" | jq -r '.result')
        block_json=$(curl -s -X POST -H "Content-Type: application/json" \
            --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$block_number_hex\", true],\"id\":2}" \
            "$SHADOW_FORK_RPC")
    elif [[ $SHADOW_FORK_FILE != "" ]]; then
        # Check if SHADOW_FORK_FILE is a URL (starts with http:// or https://)
        if [[ "$SHADOW_FORK_FILE" =~ ^https?:// ]]; then
            block_json=$(curl -s "$SHADOW_FORK_FILE")
        else
            block_json=$(cat $SHADOW_FORK_FILE)
        fi
    fi

    # Convert from hex to decimal
    local hex_timestamp=$(echo "$block_json" | jq -r '.result.timestamp // "0"')
    if [[ "$hex_timestamp" == 0x* ]]; then
        shadowfork_cutoff_time=$((hex_timestamp))
    else
        shadowfork_cutoff_time=$hex_timestamp
    fi

    if [ "$shadowfork_cutoff_time" == "0" ]; then
        echo "ERROR: Could not determine shadowfork cutoff time"
        exit 1
    fi

    # determinate latest active fork based on cutoff time and parent network's genesis.json
    if [ "$(cat $tmp_dir/genesis.json | jq ".config.amsterdamTime and .config.amsterdamTime < $shadowfork_cutoff_time")" == "true" ]; then
        has_fork="7" # gloas
        shadowfork_blob_schedule="$(cat $tmp_dir/genesis.json | jq ".config.blobSchedule.amsterdam + { \"timestamp\": .config.amsterdamTime }")"
    elif [ "$(cat $tmp_dir/genesis.json | jq ".config.osakaTime and .config.osakaTime < $shadowfork_cutoff_time")" == "true" ]; then
        has_fork="6" # fulu
        shadowfork_blob_schedule="$(cat $tmp_dir/genesis.json | jq ".config.blobSchedule.osaka + { \"timestamp\": .config.osakaTime }")"
    elif [ "$(cat $tmp_dir/genesis.json | jq ".config.pragueTime and .config.pragueTime < $shadowfork_cutoff_time")" == "true" ]; then
        has_fork="5" # electra
        shadowfork_blob_schedule="$(cat $tmp_dir/genesis.json | jq ".config.blobSchedule.prague + { \"timestamp\": .config.pragueTime }")"
    elif [ "$(cat $tmp_dir/genesis.json | jq ".config.cancunTime and .config.cancunTime < $shadowfork_cutoff_time")" == "true" ]; then
        has_fork="4" # deneb
        shadowfork_blob_schedule="$(cat $tmp_dir/genesis.json | jq ".config.blobSchedule.cancun + { \"timestamp\": .config.cancunTime }")"
    elif [ "$(cat $tmp_dir/genesis.json | jq ".config.shanghaiTime and .config.shanghaiTime < $shadowfork_cutoff_time")" == "true" ]; then
        has_fork="3" # capella
    else
        has_fork="2" # bellatrix
    fi

    # determinate latest active BPO based on cutoff time and parent network's genesis.json
    for ((i=max_bpos; i>=1; i--)); do
        if jq -e ".config.bpo${i}Time != null and .config.bpo${i}Time < $shadowfork_cutoff_time" "$tmp_dir/genesis.json" >/dev/null; then
            has_bpos="$i"

            if [ -z "$shadowfork_blob_schedule" ] || [ "$(jq -r ".timestamp" <<< "$shadowfork_blob_schedule")" -lt "$(jq -r ".config.bpo${i}Time" "$tmp_dir/genesis.json")" ]; then
                shadowfork_blob_schedule="$(cat $tmp_dir/genesis.json | jq ".config.blobSchedule.bpo${i} + { \"timestamp\": .config.bpo${i}Time }")"
            fi
            break
        fi
    done

    # Remove future BPOs that haven't activated yet at shadowfork time
    # First, filter chainspec blob schedule entries (uses hex timestamps)
    genesis_add_json $tmp_dir/chainspec.json '
        def hx: ltrimstr("0x") | explode | reduce .[] as $c (0; . * 16 + (if $c>96 then $c-87 else $c-48 end));
        .params.blobSchedule |= map(select((.timestamp | hx) <= '"$shadowfork_cutoff_time"'))
    '
    # Remove future BPO configurations from genesis files
    for ((i=max_bpos; i>has_bpos; i--)); do
        genesis_add_json $tmp_dir/genesis.json "del(.config.bpo${i}Time) | del(.config.blobSchedule.bpo${i})"
        genesis_add_json $tmp_dir/besu.json "del(.config.bpo${i}Time) | del(.config.blobSchedule.bpo${i})"
    done
}

# Calculates the activation timestamp for a given epoch
# Converts epoch number to Unix timestamp based on genesis delay and slot duration
# Args:
#   $1: Epoch number (0 for immediate activation)
# Returns:
#   Activation timestamp in seconds since Unix epoch
genesis_get_activation_time() {
    if [ "$1" == "0" ]; then
        echo "0"
    else
        # Calculate slots per epoch based on preset
        if [ "$PRESET_BASE" == "minimal" ]; then
            slots_per_epoch=8
        else
            slots_per_epoch=32
        fi
        # Convert epoch to timestamp: genesis_time + genesis_delay + (epoch * slots * slot_duration)
        epoch_delay=$(( $SLOT_DURATION_IN_SECONDS * $slots_per_epoch * $1 ))
        echo $(( $GENESIS_TIMESTAMP + $GENESIS_DELAY + $epoch_delay ))
    fi
}

# Retrieves the active blob schedule for a given timestamp
# Searches through all blob schedules to find the most recent one before the timestamp
# Args:
#   $1: Temporary directory containing blob_schedule.json
#   $2: Timestamp to find active schedule for
# Returns:
#   JSON object containing blob schedule parameters (target, max, baseFeeUpdateFraction)
genesis_get_blob_schedule() {
    local tmp_dir=$1
    local timestamp=$2

    # get latest active blob schedule based on timestamp
    local active_blob_schedule="$shadowfork_blob_schedule"

    local matching_blob_schedule=$(jq --argjson t "$timestamp" '
        (map(select(.timestamp <= $t)) | sort_by(.timestamp) | last) // ""
    ' $tmp_dir/blob_schedule.json)

    if [ -n "$matching_blob_schedule" ]; then
        active_blob_schedule="$matching_blob_schedule"
    fi

    # remove timestamp field from returned schedule (geth/besu format)
    active_blob_schedule=$(echo "$active_blob_schedule" | jq "del(.timestamp)")

    echo "$active_blob_schedule"
}

# Adds a new blob schedule entry to the blob schedule tracking file
# Ensures entries are ordered by timestamp and prevents duplicates
# Args:
#   $1: Temporary directory containing blob_schedule.json
#   $2: JSON object with blob schedule (must include timestamp field)
genesis_add_blob_schedule() {
    local tmp_dir=$1
    local blob_schedule=$2

    NEW_BLOB_SCHEDULE="$blob_schedule" \
    genesis_add_json "$tmp_dir/blob_schedule.json" '
        (env.NEW_BLOB_SCHEDULE | fromjson) as $n
        | (.[-1]?.timestamp // -1) as $last
        | if $n.timestamp > $last then
            . + [$n]
          elif $n.timestamp == $last then
            .[:-1] + [$n]
          else
            error("new entry has lower timestamp than latest: \($n.timestamp) < \($last)")
          end
    '
}

# Applies all blob schedules to the chainspec.json file
# Converts decimal timestamps to hex format for chainspec compatibility
# Args:
#   $1: Temporary directory containing blob_schedule.json and chainspec.json
genesis_apply_blob_schedule() {
    local tmp_dir=$1

    local blob_schedule=$(jq '
    def tohex: .|tonumber as $n | def go($x): if $x<16 then ("0123456789abcdef"[$x:$x+1]) else (go(($x/16|floor)) + ("0123456789abcdef"[($x%16):($x%16+1)])) end; go($n);
    map(.timestamp |= ("0x" + (.|tonumber|tohex)) | .baseFeeUpdateFraction |= ("0x" + (.|tonumber|tohex)))
    ' $tmp_dir/blob_schedule.json)

    genesis_add_json "$tmp_dir/chainspec.json" '.params.blobSchedule += '"$blob_schedule"
}

# Calculates the base fee update fraction for blob pricing
# Uses the formula: round((MAX_BLOBS * GAS_PER_BLOB) / (2 * log(1.125)))
# Args:
#   $1: Maximum number of blobs per block
# Returns:
#   Base fee update fraction as an integer
calculate_basefee_update_fraction() {
    local MAX_BLOBS=$1

    # BASE_FEE_UPDATE_FRACTION = round((MAX_BLOBS * GAS_PER_BLOB) / (2 * math.log(1.125)))
    local GAS_PER_BLOB=$((2**17))
    local BASE_FEE_UPDATE_FRACTION=$(echo "($MAX_BLOBS * $GAS_PER_BLOB) / (2 * l(1.125))" | bc -l)

    echo "($BASE_FEE_UPDATE_FRACTION + 0.5)/1" | bc
}

# Analyzes and displays the blob fee percentage changes for debugging
# Shows how much fees increase with max blobs and decrease with target blobs
# Args:
#   $1: Maximum number of blobs per block
#   $2: Target number of blobs per block
#   $3: Base fee update fraction
analyze_basefee_update_fraction() {
    local MAX_BLOBS=$1
    local TARGET_BLOBS=$2
    local BASE_FEE_UPDATE_FRACTION=$3

    local GAS_PER_BLOB=$((2**17))

    local fee_up=$(echo "e((($MAX_BLOBS - $TARGET_BLOBS) * $GAS_PER_BLOB) / $BASE_FEE_UPDATE_FRACTION)" | bc -l)
    local fee_down=$(echo "e(-($TARGET_BLOBS * $GAS_PER_BLOB) / $BASE_FEE_UPDATE_FRACTION)" | bc -l)

    # Calculate percentages
    local fee_up_pct=$(echo "100 * ($fee_up - 1)" | bc -l)
    local fee_down_pct=$(echo "100 * (1 - $fee_down)" | bc -l)

    printf "  Blob fee increase with %d blobs: +%.2f%%\n" "$MAX_BLOBS" "$fee_up_pct"
    printf "  Blob fee decrease with %d blobs: -%.2f%%\n" "$TARGET_BLOBS" "$fee_down_pct"
}

# Updates a JSON file with a JQ query in-place
# Executes the JQ query and overwrites the original file
# Args:
#   $1: Path to the JSON file to update
#   $2: JQ query string to apply to the file
genesis_add_json() {
    local file=$1
    local data=$2

    jq -c "$data" "$file" > "$file.out"
    mv "$file.out" "$file"
}

# Updates a JSON file with large data using JQ slurpfile
# Used when data is too large for command line arguments
# Args:
#   $1: Path to the JSON file to update
#   $2: Large JSON data to be used in query
#   $3: JQ query string that references $input[0] for the data
genesis_add_big_json() {
    local file=$1
    local data=$2
    local query=$3

    echo "$data" > "$file.inp"
    jq -c --slurpfile input "$file.inp" "$query" "$file" > "$file.out"
    mv "$file.out" "$file"
    rm "$file.inp"
}

# Adds an address allocation to the allocations file
# Converts ETH balance notation to wei (e.g., "1 ETH" -> "1000000000000000000")
# Args:
#   $1: Temporary directory containing allocations.json
#   $2: Ethereum address (with 0x prefix)
#   $3: Allocation object (JSON) with balance and optional code/storage
genesis_add_allocation() {
    local tmp_dir=$1
    local address=$2
    local allocation=$3

    echo "  adding allocation for $address"
    echo "$allocation" | jq -c '.balance |= gsub(" *ETH"; "000000000000000000") | {("'"$address"'"): .}' >> $tmp_dir/allocations.json
}

# Deploys system contracts required by various EIPs
# Adds deposit contract and fork-specific system contracts (EIP-4788, EIP-2935, etc.)
# Args:
#   $1: Temporary directory for storing allocations
genesis_add_system_contracts() {
    local tmp_dir=$1
    local system_contracts=$(cat /apps/el-gen/system-contracts.yaml | yq -c)
    local target_address

    echo "Adding system contracts"

    # add deposit contract
    echo -e "  genesis contract:\t$DEPOSIT_CONTRACT_ADDRESS"
    genesis_add_allocation $tmp_dir "$DEPOSIT_CONTRACT_ADDRESS" $(echo "$system_contracts" | jq -c '.deposit')

    if [ ! "$DENEB_FORK_EPOCH" == "18446744073709551615" ]; then
        # EIP-4788: Beacon block root in the EVM
        target_address=$(echo "$system_contracts" | jq -r '.eip4788_address')
        echo -e "  EIP-4788 contract:\t$target_address"
        genesis_add_allocation $tmp_dir $target_address $(echo "$system_contracts" | jq -c '.eip4788')
    fi

    if [ ! "$ELECTRA_FORK_EPOCH" == "18446744073709551615" ]; then
        # EIP-2935: Serve historical block hashes from state
        target_address=$(echo "$system_contracts" | jq -r '.eip2935_address')
        echo -e "  EIP-2935 contract:\t$target_address"
        genesis_add_allocation $tmp_dir $target_address $(echo "$system_contracts" | jq -c '.eip2935')

        # EIP-7002: Execution layer triggerable withdrawals
        target_address=$(echo "$system_contracts" | jq -r '.eip7002_address')
        echo -e "  EIP-7002 contract:\t$target_address"
        genesis_add_allocation $tmp_dir $target_address $(echo "$system_contracts" | jq -c '.eip7002')

        # EIP-7251: Increase the MAX_EFFECTIVE_BALANCE
        target_address=$(echo "$system_contracts" | jq -r '.eip7251_address')
        echo -e "  EIP-7251 contract:\t$target_address"
        genesis_add_allocation $tmp_dir $target_address $(echo "$system_contracts" | jq -c '.eip7251')
    fi
}

# Adds Bellatrix (Merge) fork properties to genesis files
# Sets up proof-of-stake transition with terminal total difficulty of 0
# Args:
#   $1: Temporary directory containing genesis files
genesis_add_bellatrix() {
    local tmp_dir=$1
    echo "Adding bellatrix genesis properties"

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "mergeNetsplitBlock": 0,
        "terminalTotalDifficulty": 0,
        "terminalTotalDifficultyPassed": true
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "mergeForkIdTransition": "0x0",
        "terminalTotalDifficulty": "0x0"
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "preMergeForkBlock": 0,
        "terminalTotalDifficulty": 0,
        "ethash": {}
    }'
}

# Adds Capella (Shanghai) fork properties to genesis files
# Enabled EIPs: 4895, 3855, 3651, 3860
# Args:
#   $1: Temporary directory containing genesis files
genesis_add_capella() {
    local tmp_dir=$1
    echo "Adding capella genesis properties"
    local shanghai_time=$(genesis_get_activation_time $CAPELLA_FORK_EPOCH)
    local shanghai_time_hex="0x$(printf "%x" $shanghai_time)"

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "shanghaiTime": '"$shanghai_time"'
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "eip4895TransitionTimestamp": "'$shanghai_time_hex'",
        "eip3855TransitionTimestamp": "'$shanghai_time_hex'",
        "eip3651TransitionTimestamp": "'$shanghai_time_hex'",
        "eip3860TransitionTimestamp": "'$shanghai_time_hex'"
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "shanghaiTime": '"$shanghai_time"'
    }'
}

# Adds Deneb (Cancun) fork properties to genesis files
# Enabled EIPs: 4844, 4788, 1153, 5656, 6780
# Args:
#   $1: Temporary directory containing genesis files
genesis_add_deneb() {
    local tmp_dir=$1
    echo "Adding deneb genesis properties"
    local cancun_time=$(genesis_get_activation_time $DENEB_FORK_EPOCH)
    local cancun_time_hex="0x$(printf "%x" $cancun_time)"
    local target_blobs_per_block_cancun=3
    local max_blobs_per_block_cancun=6
    local base_fee_update_fraction_cancun=3338477

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "cancunTime": '"$cancun_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule = {
        "cancun": {
            "target": '"$target_blobs_per_block_cancun"',
            "max": '"$max_blobs_per_block_cancun"',
            "baseFeeUpdateFraction": '"$base_fee_update_fraction_cancun"'
        }
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "eip4844TransitionTimestamp": "'$cancun_time_hex'",
        "eip4788TransitionTimestamp": "'$cancun_time_hex'",
        "eip1153TransitionTimestamp": "'$cancun_time_hex'",
        "eip5656TransitionTimestamp": "'$cancun_time_hex'",
        "eip6780TransitionTimestamp": "'$cancun_time_hex'"
    }'
    genesis_add_blob_schedule $tmp_dir '{
        "timestamp": '$cancun_time',
        "target": '"$target_blobs_per_block_cancun"',
        "max": '"$max_blobs_per_block_cancun"',
        "baseFeeUpdateFraction": '"$base_fee_update_fraction_cancun"'
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "cancunTime": '"$cancun_time"'
    }'
    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule = {
        "cancun": {
            "target": '"$target_blobs_per_block_cancun"',
            "max": '"$max_blobs_per_block_cancun"',
            "baseFeeUpdateFraction": '"$base_fee_update_fraction_cancun"'
        }
    }'
}

# Adds Electra (Prague) fork properties to genesis files
# Enabled EIPs: 2537, 2935, 6110, 7002, 7251, 7623, 7702
# Args:
#   $1: Temporary directory containing genesis files
genesis_add_electra() {
    local tmp_dir=$1
    echo "Adding electra genesis properties"
    local prague_time=$(genesis_get_activation_time $ELECTRA_FORK_EPOCH)
    local prague_time_hex="0x$(printf "%x" $prague_time)"

    # Calculate basefee update fraction if not specified
    if [ -z "$BASEFEE_UPDATE_FRACTION_ELECTRA" ] || [ "$BASEFEE_UPDATE_FRACTION_ELECTRA" == "0" ]; then
        BASEFEE_UPDATE_FRACTION_ELECTRA=$(calculate_basefee_update_fraction $MAX_BLOBS_PER_BLOCK_ELECTRA)
        echo "Calculated BASEFEE_UPDATE_FRACTION_ELECTRA: $BASEFEE_UPDATE_FRACTION_ELECTRA"
        analyze_basefee_update_fraction $MAX_BLOBS_PER_BLOCK_ELECTRA $TARGET_BLOBS_PER_BLOCK_ELECTRA $BASEFEE_UPDATE_FRACTION_ELECTRA
    fi

    # Load system contract addresses for Electra
    local system_contracts=$(cat /apps/el-gen/system-contracts.yaml | yq -c)
    local eip7002_contract=$(echo "$system_contracts" | jq -r '.eip7002_address')  # Withdrawal requests
    local eip7251_contract=$(echo "$system_contracts" | jq -r '.eip7251_address')  # Consolidation requests

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'",
        "pragueTime": '"$prague_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "prague": {
            "target": '"$TARGET_BLOBS_PER_BLOCK_ELECTRA"',
            "max": '"$MAX_BLOBS_PER_BLOCK_ELECTRA"',
            "baseFeeUpdateFraction": '"$BASEFEE_UPDATE_FRACTION_ELECTRA"'
        }
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'",
        "eip2537TransitionTimestamp": "'$prague_time_hex'",
        "eip2935TransitionTimestamp": "'$prague_time_hex'",
        "eip6110TransitionTimestamp": "'$prague_time_hex'",
        "eip7002TransitionTimestamp": "'$prague_time_hex'",
        "eip7251TransitionTimestamp": "'$prague_time_hex'",
        "eip7623TransitionTimestamp": "'$prague_time_hex'",
        "eip7702TransitionTimestamp": "'$prague_time_hex'"
    }'
    genesis_add_blob_schedule $tmp_dir '{
        "timestamp": '$prague_time',
        "target": '"$TARGET_BLOBS_PER_BLOCK_ELECTRA"',
        "max": '"$MAX_BLOBS_PER_BLOCK_ELECTRA"',
        "baseFeeUpdateFraction": '"$BASEFEE_UPDATE_FRACTION_ELECTRA"'
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'",
        "withdrawalRequestContractAddress": "'"$eip7002_contract"'",
        "consolidationRequestContractAddress": "'"$eip7251_contract"'",
        "pragueTime": '"$prague_time"'
    }'
    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
        "prague": {
            "target": '"$TARGET_BLOBS_PER_BLOCK_ELECTRA"',
            "max": '"$MAX_BLOBS_PER_BLOCK_ELECTRA"',
            "baseFeeUpdateFraction": '"$BASEFEE_UPDATE_FRACTION_ELECTRA"'
        }
    }'
}

# Adds Fulu (Osaka) fork properties to genesis files
# Enabled EIPs: 7594, 7823, 7825, 7883, 7918, 7934, 7939, 7951
# Args:
#   $1: Temporary directory containing genesis files
genesis_add_fulu() {
    local tmp_dir=$1
    echo "Adding fulu genesis properties"
    local osaka_time=$(genesis_get_activation_time $FULU_FORK_EPOCH)
    local osaka_time_hex="0x$(printf "%x" $osaka_time)"
    local latest_blob_schedule=$(genesis_get_blob_schedule $tmp_dir $osaka_time)

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "osakaTime": '"$osaka_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "osaka": '"$latest_blob_schedule"'
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "eip7594TransitionTimestamp": "'$osaka_time_hex'",
        "eip7823TransitionTimestamp": "'$osaka_time_hex'",
        "eip7825TransitionTimestamp": "'$osaka_time_hex'",
        "eip7883TransitionTimestamp": "'$osaka_time_hex'",
        "eip7918TransitionTimestamp": "'$osaka_time_hex'",
        "eip7934TransitionTimestamp": "'$osaka_time_hex'",
        "eip7939TransitionTimestamp": "'$osaka_time_hex'",
        "eip7951TransitionTimestamp": "'$osaka_time_hex'"
    }'
    # blob schedule will only be added via bpo from osaka onwards

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "osakaTime": '"$osaka_time"'
    }'
    # no named blob schedule for besu
}

# Adds BPOs (Blob Parameter Only) to the blob schedule
# BPOs allow dynamic blob parameter updates without hard forks
# Args:
#   $1: Temporary directory containing genesis files
#   $2: Minimum BPO number to process
#   $3: Maximum BPO number to process
genesis_add_bpos() {
    local tmp_dir=$1
    local min_bpo=$2
    local max_bpo=$3
    echo "Adding blob schedule (BPOs and fork-based entries)"

    # Add regular BPO_N through BPO_M
    local i
    for ((i=min_bpo; i<=max_bpo; i++)); do
        local bpo_epoch_var="BPO_${i}_EPOCH"
        local bpo_epoch="${!bpo_epoch_var}"

        if [ "$i" -le "$has_bpos" ]; then
            continue
        fi

        # Break if variable is not defined
        if [ -z "$bpo_epoch" ]; then
            break
        fi

        # Skip if has max value (not scheduled)
        if [ "$bpo_epoch" != "18446744073709551615" ]; then
            local target_var="BPO_${i}_TARGET_BLOBS"
            local max_var="BPO_${i}_MAX_BLOBS"
            local fraction_var="BPO_${i}_BASE_FEE_UPDATE_FRACTION"

            # Calculate fraction based on max value (or use explicit if provided and non-zero)
            local fraction="${!fraction_var}"
            if [ -z "$fraction" ] || [ "$fraction" = "0" ]; then
                fraction=$(calculate_basefee_update_fraction "${!max_var}")
                echo "  Calculated baseFeeUpdateFraction: $fraction"
                analyze_basefee_update_fraction "${!max_var}" "${!target_var}" "$fraction"
            fi

            echo "Adding BPO $i at epoch $bpo_epoch (target: ${!target_var}, max: ${!max_var}, fraction: $fraction)"

            genesis_add_blob_schedule $tmp_dir '{
                "timestamp": '"$(genesis_get_activation_time $bpo_epoch)"',
                "target": '"${!target_var}"',
                "max": '"${!max_var}"',
                "baseFeeUpdateFraction": '"$fraction"'
            }'

            genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
                "bpo'$i'": {
                    "target": '"${!target_var}"',
                    "max": '"${!max_var}"',
                    "baseFeeUpdateFraction": '"$fraction"'
                }
            }'

            genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
                "bpo'$i'": {
                    "target": '"${!target_var}"',
                    "max": '"${!max_var}"',
                    "baseFeeUpdateFraction": '"$fraction"'
                }
            }'
        fi
    done
}

# Adds Gloas (Amsterdam) fork properties to genesis files
# Enabled EIPs: 7928
# Args:
#   $1: Temporary directory containing genesis files
genesis_add_gloas() {
    local tmp_dir=$1
    echo "Adding gloas genesis properties"
    local amsterdam_time=$(genesis_get_activation_time $GLOAS_FORK_EPOCH)
    local amsterdam_time_hex="0x$(printf "%x" $amsterdam_time)"
    local latest_blob_schedule=$(genesis_get_blob_schedule $tmp_dir $amsterdam_time)

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "amsterdamTime": '"$amsterdam_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "amsterdam": '"$latest_blob_schedule"'
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "eip7928TransitionTimestamp": "'$amsterdam_time_hex'"
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "amsterdamTime": '"$amsterdam_time"'
    }'

}

# Adds EIP-7805 fork properties to genesis files
# Enabled EIPs: 7805
# Args:
#   $1: Temporary directory containing genesis files
genesis_add_eip7805() {
    local tmp_dir=$1
    echo "Adding eip7805 genesis properties"
    local eip7805_time=$(genesis_get_activation_time $EIP7805_FORK_EPOCH)
    local eip7805_time_hex="0x$(printf "%x" $eip7805_time)"
    local latest_blob_schedule=$(genesis_get_blob_schedule $tmp_dir $eip7805_time)

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "eip7805Time": '"$eip7805_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "eip7805": '"$latest_blob_schedule"'
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "eip7805TransitionTimestamp": "'$eip7805_time_hex'"
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "eip7805Time": '"$eip7805_time"'
    }'
}
