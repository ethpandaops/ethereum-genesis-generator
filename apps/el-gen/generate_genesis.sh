#!/bin/bash

setup_shadowfork() {
    local network_name=$1
    local tmp_dir=$2

    # Set shadowfork properties
    has_fork="5" # electra

    # Download genesis files from base network
    wget -O $tmp_dir/genesis.json https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/genesis.json
    wget -O $tmp_dir/chainspec.json https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/chainspec.json
    wget -O $tmp_dir/besu.json https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/besu.json

    # Validate deposit contract address matches base network
    base_deposit_contract=$(wget -qO- https://raw.githubusercontent.com/eth-clients/$network_name/refs/heads/main/metadata/deposit_contract.txt)
    if [ "$DEPOSIT_CONTRACT_ADDRESS" != "$base_deposit_contract" ]; then
        echo "ERROR: DEPOSIT_CONTRACT_ADDRESS ($DEPOSIT_CONTRACT_ADDRESS) must match $network_name ($base_deposit_contract) for shadowfork"
        exit 1
    fi
}

generate_genesis() {
    set +x
    export CHAIN_ID_HEX="0x$(printf "%x" $CHAIN_ID)"
    export GENESIS_TIMESTAMP_HEX="0x$(printf "%x" $GENESIS_TIMESTAMP)"
    export GENESIS_GASLIMIT_HEX="0x$(printf "%x" $GENESIS_GASLIMIT)"
    export GENESIS_DIFFICULTY_HEX="0x$(printf "%x" $GENESIS_DIFFICULTY)"

    out_dir=$1
    tmp_dir=$(mktemp -d -t ci-XXXXXXXXXX)

    is_shadowfork="1"
    has_fork="0"

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
        setup_shadowfork "mainnet" "$tmp_dir"
    elif [ "$CHAIN_ID" == "11155111" ]; then
        # sepolia shadowfork
        setup_shadowfork "sepolia" "$tmp_dir"
    elif [ "$CHAIN_ID" == "17000" ]; then
        # holesky shadowfork
        setup_shadowfork "holesky" "$tmp_dir"
    elif [ "$CHAIN_ID" == "560048" ]; then
        # hoodi shadowfork
        setup_shadowfork "hoodi" "$tmp_dir"
    else
        # Generate base genesis.json, chainspec.json and besu.json
        envsubst < /apps/el-gen/tpl-genesis.json   > $tmp_dir/genesis.json
        envsubst < /apps/el-gen/tpl-chainspec.json > $tmp_dir/chainspec.json
        envsubst < /apps/el-gen/tpl-besu.json      > $tmp_dir/besu.json
        is_shadowfork="0"
        has_fork="0"
    fi

    # Add additional fork properties
    [ $has_fork -lt 2 ] && genesis_add_bellatrix $tmp_dir
    [ $has_fork -lt 3 ] && [ ! "$CAPELLA_FORK_EPOCH"   == "18446744073709551615" ] && genesis_add_capella $tmp_dir
    [ $has_fork -lt 4 ] && [ ! "$DENEB_FORK_EPOCH"     == "18446744073709551615" ] && genesis_add_deneb $tmp_dir
    [ $has_fork -lt 5 ] && [ ! "$ELECTRA_FORK_EPOCH"   == "18446744073709551615" ] && genesis_add_electra $tmp_dir
    [ $has_fork -lt 6 ] && [ ! "$FULU_FORK_EPOCH"      == "18446744073709551615" ] && genesis_add_fulu $tmp_dir
    [ $has_fork -lt 7 ] && [ ! "$GLOAS_FORK_EPOCH"     == "18446744073709551615" ] && genesis_add_gloas $tmp_dir
    [ $has_fork -lt 8 ] && [ ! "$EIP7805_FORK_EPOCH"   == "18446744073709551615" ] && genesis_add_eip7805 $tmp_dir
    genesis_add_bpo $tmp_dir

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

genesis_get_activation_time() {
    if [ "$1" == "0" ]; then
        echo "0"
    else
        if [ "$PRESET_BASE" == "minimal" ]; then
            slots_per_epoch=8
        else
            slots_per_epoch=32
        fi
        epoch_delay=$(( $SLOT_DURATION_IN_SECONDS * $slots_per_epoch * $1 ))
        echo $(( $GENESIS_TIMESTAMP + $GENESIS_DELAY + $epoch_delay ))
    fi
}

calculate_basefee_update_fraction() {
    MAX_BLOBS=$1

    # BASE_FEE_UPDATE_FRACTION = round((MAX_BLOBS * GAS_PER_BLOB) / (2 * math.log(1.125)))
    GAS_PER_BLOB=$((2**17))
    BASE_FEE_UPDATE_FRACTION=$(echo "($MAX_BLOBS * $GAS_PER_BLOB) / (2 * l(1.125))" | bc -l)

    echo "($BASE_FEE_UPDATE_FRACTION + 0.5)/1" | bc
}

analyze_basefee_update_fraction() {
    MAX_BLOBS=$1
    TARGET_BLOBS=$2
    BASE_FEE_UPDATE_FRACTION=$3

    GAS_PER_BLOB=$((2**17))

    fee_up=$(echo "e((($MAX_BLOBS - $TARGET_BLOBS) * $GAS_PER_BLOB) / $BASE_FEE_UPDATE_FRACTION)" | bc -l)
    fee_down=$(echo "e(-($TARGET_BLOBS * $GAS_PER_BLOB) / $BASE_FEE_UPDATE_FRACTION)" | bc -l)

    # Calculate percentages
    fee_up_pct=$(echo "100 * ($fee_up - 1)" | bc -l)
    fee_down_pct=$(echo "100 * (1 - $fee_down)" | bc -l)

    printf "  Blob fee increase with %d blobs: +%.2f%%\n" "$MAX_BLOBS" "$fee_up_pct"
    printf "  Blob fee decrease with %d blobs: -%.2f%%\n" "$TARGET_BLOBS" "$fee_down_pct"
}

genesis_add_json() {
    file=$1
    data=$2

    echo "$data" > /data/change.json
    cp "$file" /data/input.json
    jq -c "$data" "$file" > "$file.out"
    mv "$file.out" "$file"
}

genesis_add_big_json() {
    file=$1
    data=$2
    query=$3

    echo "$data" > "$file.inp"
    jq -c --slurpfile input "$file.inp" "$query" "$file" > "$file.out"
    mv "$file.out" "$file"
    rm "$file.inp"
}

genesis_add_allocation() {
    tmp_dir=$1
    address=$2
    allocation=$3

    echo "  adding allocation for $address"
    echo "$allocation" | jq -c '.balance |= gsub(" *ETH"; "000000000000000000") | {("'"$address"'"): .}' >> $tmp_dir/allocations.json
}

genesis_add_system_contracts() {
    tmp_dir=$1
    system_contracts=$(cat /apps/el-gen/system-contracts.yaml | yq -c)

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

genesis_add_bellatrix() {
    tmp_dir=$1
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

# add capella fork properties
genesis_add_capella() {
    tmp_dir=$1
    echo "Adding capella genesis properties"
    shanghai_time=$(genesis_get_activation_time $CAPELLA_FORK_EPOCH)
    shanghai_time_hex="0x$(printf "%x" $shanghai_time)"

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

# add deneb fork properties
genesis_add_deneb() {
    tmp_dir=$1
    echo "Adding deneb genesis properties"
    cancun_time=$(genesis_get_activation_time $DENEB_FORK_EPOCH)
    cancun_time_hex="0x$(printf "%x" $cancun_time)"
    target_blobs_per_block_cancun=3
    max_blobs_per_block_cancun=6
    base_fee_update_fraction_cancun=3338477
    base_fee_update_fraction_cancun_hex="0x$(printf "%x" $base_fee_update_fraction_cancun)"

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

    if [ "$ELECTRA_FORK_EPOCH" != "0" ]; then
        genesis_add_json $tmp_dir/chainspec.json '.params.blobSchedule += [
            {
                "timestamp": "'$cancun_time_hex'",
                "target": '"$target_blobs_per_block_cancun"',
                "max": '"$max_blobs_per_block_cancun"',
                "baseFeeUpdateFraction": "'$base_fee_update_fraction_cancun_hex'"
            }
        ]'
    fi

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

# add electra fork properties
genesis_add_electra() {
    tmp_dir=$1
    echo "Adding electra genesis properties"
    prague_time=$(genesis_get_activation_time $ELECTRA_FORK_EPOCH)
    prague_time_hex="0x$(printf "%x" $prague_time)"

    # Calculate basefee update fraction if not specified
    if [ -z "$BASEFEE_UPDATE_FRACTION_ELECTRA" ] || [ "$BASEFEE_UPDATE_FRACTION_ELECTRA" == "0" ]; then
        BASEFEE_UPDATE_FRACTION_ELECTRA=$(calculate_basefee_update_fraction $MAX_BLOBS_PER_BLOCK_ELECTRA)
        echo "Calculated BASEFEE_UPDATE_FRACTION_ELECTRA: $BASEFEE_UPDATE_FRACTION_ELECTRA"
        analyze_basefee_update_fraction $MAX_BLOBS_PER_BLOCK_ELECTRA $TARGET_BLOBS_PER_BLOCK_ELECTRA $BASEFEE_UPDATE_FRACTION_ELECTRA
    fi

    basefee_update_fraction_electra_hex="0x$(printf "%x" $BASEFEE_UPDATE_FRACTION_ELECTRA)"
    # load electra system contracts
    system_contracts=$(cat /apps/el-gen/system-contracts.yaml | yq -c)
    EIP7002_CONTRACT_ADDRESS=$(echo "$system_contracts" | jq -r '.eip7002_address')
    EIP7251_CONTRACT_ADDRESS=$(echo "$system_contracts" | jq -r '.eip7251_address')

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

    if [ "$FULU_FORK_EPOCH" != "0" ]; then
        genesis_add_json $tmp_dir/chainspec.json '.params.blobSchedule += [
            {
                "timestamp": "'$prague_time_hex'",
                "target": '"$TARGET_BLOBS_PER_BLOCK_ELECTRA"',
                "max": '"$MAX_BLOBS_PER_BLOCK_ELECTRA"',
                "baseFeeUpdateFraction": "'$basefee_update_fraction_electra_hex'"
            }
        ]'
    fi

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'",
        "withdrawalRequestContractAddress": "'"$EIP7002_CONTRACT_ADDRESS"'",
        "consolidationRequestContractAddress": "'"$EIP7251_CONTRACT_ADDRESS"'",
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

# add fulu fork properties
genesis_add_fulu() {
    tmp_dir=$1
    echo "Adding fulu genesis properties"
    osaka_time=$(genesis_get_activation_time $FULU_FORK_EPOCH)
    osaka_time_hex="0x$(printf "%x" $osaka_time)"

    # Calculate basefee update fraction if not specified
    if [ -z "$BASEFEE_UPDATE_FRACTION_ELECTRA" ] || [ "$BASEFEE_UPDATE_FRACTION_ELECTRA" == "0" ]; then
        BASEFEE_UPDATE_FRACTION_ELECTRA=$(calculate_basefee_update_fraction $MAX_BLOBS_PER_BLOCK_ELECTRA)
        echo "Calculated BASEFEE_UPDATE_FRACTION_ELECTRA: $BASEFEE_UPDATE_FRACTION_ELECTRA"
        analyze_basefee_update_fraction $MAX_BLOBS_PER_BLOCK_ELECTRA $TARGET_BLOBS_PER_BLOCK_ELECTRA $BASEFEE_UPDATE_FRACTION_ELECTRA
    fi

    basefee_update_fraction_electra_hex="0x$(printf "%x" $BASEFEE_UPDATE_FRACTION_ELECTRA)"

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "osakaTime": '"$osaka_time"'
    }'

    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "osaka": {
            "target": '"$TARGET_BLOBS_PER_BLOCK_ELECTRA"',
            "max": '"$MAX_BLOBS_PER_BLOCK_ELECTRA"',
            "baseFeeUpdateFraction": '"$BASEFEE_UPDATE_FRACTION_ELECTRA"'
        }
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
    # blob schedule will only be added via bpo not from osaka onwards

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "osakaTime": '"$osaka_time"'
    }'

    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
        "osaka": {
            "target": '"$TARGET_BLOBS_PER_BLOCK_ELECTRA"',
            "max": '"$MAX_BLOBS_PER_BLOCK_ELECTRA"',
            "baseFeeUpdateFraction": '"$BASEFEE_UPDATE_FRACTION_ELECTRA"'
        }
    }'

}

# Add gloas fork properties
genesis_add_gloas() {
    tmp_dir=$1
    echo "Adding gloas genesis properties"
    amsterdam_time=$(genesis_get_activation_time $GLOAS_FORK_EPOCH)
    amsterdam_time_hex="0x$(printf "%x" $amsterdam_time)"

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "amsterdamTime": '"$amsterdam_time"'
    }'

    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "amsterdam": {
            "target": '"$TARGET_BLOBS_PER_BLOCK_AMSTERDAM"',
            "max": '"$MAX_BLOBS_PER_BLOCK_AMSTERDAM"',
            "baseFeeUpdateFraction": '"$BASEFEE_UPDATE_FRACTION_AMSTERDAM"'
        }
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "eip7928TransitionTimestamp": "'$amsterdam_time_hex'"
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "amsterdamTime": '"$amsterdam_time"'
    }'

    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
        "amsterdam": {
            "target": '"$TARGET_BLOBS_PER_BLOCK_AMSTERDAM"',
            "max": '"$MAX_BLOBS_PER_BLOCK_AMSTERDAM"',
            "baseFeeUpdateFraction": '"$BASEFEE_UPDATE_FRACTION_AMSTERDAM"'
        }
    }'
}

# add eip7805 fork properties
genesis_add_eip7805() {
    tmp_dir=$1
    echo "Adding eip7805 genesis properties"
    eip7805_time=$(genesis_get_activation_time $EIP7805_FORK_EPOCH)
    eip7805_time_hex="0x$(printf "%x" $eip7805_time)"

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "eip7805Time": '"$eip7805_time"'
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

genesis_add_bpo() {
    tmp_dir=$1
    echo "Adding bpo genesis properties"
    for i in {1..5}; do
        bpo_var="BPO_${i}_EPOCH"
        bpo_val=${!bpo_var}

        # Skip if variable is not defined, is empty, or has max value
        if [ -z "$bpo_val" ] || [ "$bpo_val" = "18446744073709551615" ]; then
            continue
        fi

        bpo_time=$(genesis_get_activation_time $bpo_val)
        bpo_time_hex="0x$(printf "%x" $bpo_time)"

        target_var="BPO_${i}_TARGET_BLOBS"
        max_var="BPO_${i}_MAX_BLOBS"
        fraction_var="BPO_${i}_BASE_FEE_UPDATE_FRACTION"
        fraction_value=${!fraction_var}

        # Calculate basefee update fraction if not specified
        if [ -z "$fraction_value" ] || [ "$fraction_value" == "0" ]; then
            fraction_value=$(calculate_basefee_update_fraction ${!max_var} ${!target_var})
            echo "Calculated BPO_${i}_BASE_FEE_UPDATE_FRACTION: $fraction_value"
            analyze_basefee_update_fraction ${!max_var} ${!target_var} $fraction_value
        fi

        fraction_var_hex="0x$(printf "%x" $fraction_value)"
        max_blobs_per_tx_var="BPO_${i}_MAX_BLOBS_PER_TX"

        # genesis.json
        genesis_add_json $tmp_dir/genesis.json '.config += {
            "bpo'"$i"'Time": '"$bpo_time"'
        }'
        genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
            "bpo'"$i"'": {
                "target": '"${!target_var}"',
                "max": '"${!max_var}"',
                "baseFeeUpdateFraction": '"$fraction_value"'
            }
        }'


        # chainspec.json

        genesis_add_json $tmp_dir/chainspec.json '.params.blobSchedule += [
            {
                "timestamp": "'$bpo_time_hex'",
                "target": '"${!target_var}"',
                "max": '"${!max_var}"',
                "baseFeeUpdateFraction": "'$fraction_var_hex'"
            }
        ]'

        # besu.json
        genesis_add_json $tmp_dir/besu.json '.config += {
            "bpo'"$i"'Time": '"$bpo_time"'
        }'


        genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
            "bpo'"$i"'": {
                "target": '"${!target_var}"',
                "max": '"${!max_var}"',
                "baseFeeUpdateFraction": '"$fraction_value"'
            }
        }'
    done
}
