#!/bin/bash

generate_genesis() {
    set +x
    export CHAIN_ID_HEX="0x$(printf "%x" $CHAIN_ID)"
    export GENESIS_TIMESTAMP_HEX="0x$(printf "%x" $GENESIS_TIMESTAMP)"
    export GENESIS_GASLIMIT_HEX="0x$(printf "%x" $GENESIS_GASLIMIT)"

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

    if [ "$CHAIN_ID" == "1" ]; then
        # mainnet shadowfork
        has_fork="4" # deneb
        cp /apps/el-gen/mainnet/genesis.json $tmp_dir/genesis.json
        cp /apps/el-gen/mainnet/chainspec.json $tmp_dir/chainspec.json
        cp /apps/el-gen/mainnet/besu_genesis.json $tmp_dir/besu.json
    elif [ "$CHAIN_ID" == "11155111" ]; then
        # sepolia shadowfork
        has_fork="4" # deneb
        cp /apps/el-gen/sepolia/genesis.json $tmp_dir/genesis.json
        cp /apps/el-gen/sepolia/chainspec.json $tmp_dir/chainspec.json
        cp /apps/el-gen/sepolia/besu_genesis.json $tmp_dir/besu.json
    elif [ "$CHAIN_ID" == "17000" ]; then
        # holesky shadowfork
        has_fork="4" # deneb
        cp /apps/el-gen/holesky/genesis.json $tmp_dir/genesis.json
        cp /apps/el-gen/holesky/chainspec.json $tmp_dir/chainspec.json
        cp /apps/el-gen/holesky/besu_genesis.json $tmp_dir/besu.json
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
                if [ -f "$additional_contracts" ]; then
                    additional_contracts=$(cat $additional_contracts)
                else
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
        genesis_add_json $tmp_dir/genesis.json '.alloc += '"$allocations"
        genesis_add_json $tmp_dir/chainspec.json '.accounts += '"$allocations"
        genesis_add_json $tmp_dir/besu.json '.alloc += '"$allocations"
    fi

    cat $tmp_dir/genesis.json | jq > $out_dir/genesis.json
    cat $tmp_dir/chainspec.json | jq > $out_dir/chainspec.json
    cat $tmp_dir/besu.json | jq > $out_dir/besu.json
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

genesis_add_json() {
    file=$1
    data=$2

    jq -c "$data" "$file" > "$file.out"
    mv "$file.out" "$file"
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

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "cancunTime": '"$cancun_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {}'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "cancun": {
            "target": '"$target_blobs_per_block_cancun"',
            "max": '"$max_blobs_per_block_cancun"'
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

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "cancunTime": '"$cancun_time"'
    }'
    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {}'
    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
        "cancun": {
            "target": '"$target_blobs_per_block_cancun"',
            "max": '"$max_blobs_per_block_cancun"'
        }
    }'
}

# add electra fork properties
genesis_add_electra() {
    tmp_dir=$1
    echo "Adding electra genesis properties"
    prague_time=$(genesis_get_activation_time $ELECTRA_FORK_EPOCH)
    prague_time_hex="0x$(printf "%x" $prague_time)"
    target_blobs_per_block_prague=$TARGET_BLOBS_PER_BLOCK_ELECTRA
    max_blobs_per_block_prague=$MAX_BLOBS_PER_BLOCK_ELECTRA

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'",
        "pragueTime": '"$prague_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "prague": {
            "target": '"$target_blobs_per_block_prague"',
            "max": '"$max_blobs_per_block_prague"'
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
        "eip7702TransitionTimestamp": "'$prague_time_hex'"
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'",
        "pragueTime": '"$prague_time"'
    }'
    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
        "prague": {
            "target": '"$target_blobs_per_block_prague"',
            "max": '"$max_blobs_per_block_prague"'
        }
    }'
}

# add fulu fork properties
genesis_add_fulu() {
    tmp_dir=$1
    echo "Adding fulu genesis properties"
    osaka_time=$(genesis_get_activation_time $FULU_FORK_EPOCH)
    osaka_time_hex="0x$(printf "%x" $osaka_time)"
    target_blobs_per_block_osaka=$TARGET_BLOBS_PER_BLOCK_FULU
    max_blobs_per_block_osaka=$MAX_BLOBS_PER_BLOCK_FULU

    # genesis.json
    genesis_add_json $tmp_dir/genesis.json '.config += {
        "osakaTime": '"$osaka_time"'
    }'
    genesis_add_json $tmp_dir/genesis.json '.config.blobSchedule += {
        "osaka": {
            "target": '"$target_blobs_per_block_osaka"',
            "max": '"$max_blobs_per_block_osaka"'
        }
    }'

    # chainspec.json
    genesis_add_json $tmp_dir/chainspec.json '.params += {
        "eip7692TransitionTimestamp": "'$osaka_time_hex'"
    }'

    # besu.json
    genesis_add_json $tmp_dir/besu.json '.config += {
        "osakaTime": '"$osaka_time"'
    }'
    genesis_add_json $tmp_dir/besu.json '.config.blobSchedule += {
        "osaka": {
            "target": '"$target_blobs_per_block_osaka"',
            "max": '"$max_blobs_per_block_osaka"'
        }
    }'
}
