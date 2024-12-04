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
    # 2 - bellatrix
    # 3 - capella
    # 4 - deneb
    # 5 - electra
    # 6 - fulu
    
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
    if [ $has_fork -lt 2 ]; then
        if [ "$BELLATRIX_FORK_EPOCH" -gt "0" ] && [ "$BELLATRIX_FORK_EPOCH" -lt "18446744073709551615" ]; then
            genesis_add_pre_bellatrix $tmp_dir
        else
            genesis_add_post_bellatrix $tmp_dir
        fi
    fi
    [ $has_fork -lt 3 ] && [ "$CAPELLA_FORK_EPOCH" -lt "18446744073709551615" ] && genesis_add_capella $tmp_dir
    [ $has_fork -lt 4 ] && [ "$DENEB_FORK_EPOCH"   -lt "18446744073709551615" ] && genesis_add_deneb $tmp_dir
    [ $has_fork -lt 5 ] && [ "$ELECTRA_FORK_EPOCH" -lt "18446744073709551615" ] && genesis_add_electra $tmp_dir
    [ $has_fork -lt 6 ] && [ "$FULU_FORK_EPOCH"    -lt "18446744073709551615" ] && genesis_add_fulu $tmp_dir

    if [ "$is_shadowfork" == "0" ]; then
        # add genesis allocations
        # 1. allocate 1 wei to all possible pre-compiles.
        #    see https://github.com/ethereum/EIPs/issues/716 "SpuriousDragon RIPEMD bug"
        #for index in $(seq 0 255);
        #do
        #    address=$(printf "0x%040x" $index)
        #    genesis_add_allocation $tmp_dir $address "1"
        #done

        # 2. add system contracts
        genesis_add_system_contracts $tmp_dir

        # 3. add prefunded wallets and additional contracts from el/genesis-config.yaml
        if [ -f /config/el/genesis-config.yaml ]; then
            envsubst < /config/el/genesis-config.yaml | yq -o=json | jq -c > $tmp_dir/el-genesis-config.json

            el_mnemonic=$(jq -r '.mnemonic' $tmp_dir/el-genesis-config.json)
            if [ -z "$el_mnemonic" ]; then
                el_mnemonic=$EL_AND_CL_MNEMONIC
            fi

            # 3.1 add el_premine wallets from menmonic & derivation path
            for premine in $(cat $tmp_dir/el-genesis-config.json | jq -c '.el_premine | to_entries[]');
            do
                path=$(echo $premine | jq -r '.key')
                address=$(geth-hdwallet -mnemonic "$el_mnemonic" -path "$path" | grep "public address:" | awk '{print $3}')
                balance=$(echo $premine | jq -r '.value')
                genesis_add_allocation $tmp_dir $address $balance
            done

            # 3.2 add el_premine_addrs wallets
            for premine in $(cat $tmp_dir/el-genesis-config.json | jq -c '.el_premine_addrs | to_entries[]');
            do
                address=$(echo $premine | jq -r '.key')
                balance=$(echo $premine | jq -r '.value')
                genesis_add_allocation $tmp_dir $address $balance
            done

            # 3.3 add additional_preloaded_contracts
            additional_contracts=$(cat $tmp_dir/el-genesis-config.json | jq -c '.additional_preloaded_contracts')
            if ! [[ "$additional_contracts" == {* ]]; then
                if [ -f "$additional_contracts" ]; then
                    additional_contracts=$(cat $additional_contracts | jq -c)
                else
                    additional_contracts="{}"
                fi
            fi

            for premine in $(echo "$additional_contracts" | jq -c 'to_entries[]');
            do
                address=$(echo $premine | jq -r '.key')
                balance=$(echo $premine | jq -r '.value')
                genesis_add_allocation $tmp_dir $address $balance
            done
        fi
    fi

    cat $tmp_dir/genesis.json | jq > $out_dir/genesis.json
    cat $tmp_dir/chainspec.json | jq > $out_dir/chainspec.json
    cat $tmp_dir/besu.json | jq > $out_dir/besu.json
    rm -rf $tmp_dir
}

genesis_get_activation_time() {
    if [ "$PRESET_BASE" == "minimal" ]; then
        slots_per_epoch=8
    else
        slots_per_epoch=32
    fi
    epoch_delay=$(( $SLOT_DURATION_IN_SECONDS * $slots_per_epoch * $1 ))
    echo $(( $GENESIS_TIMESTAMP + $GENESIS_DELAY + $epoch_delay ))
}

genesis_add_allocation() {
    tmp_dir=$1
    address=$2
    allocation=$3

    if ! [[ "$allocation" == {* ]]; then
        allocation='{"balance": "'$allocation'"}'
    fi

    balance=$(echo $allocation | jq -r '.balance' | sed 's/ *ETH/000000000000000000/')
    allocation=$(echo $allocation | jq -c '.balance = "'$balance'"')

    echo "Adding allocation for $address"
    genesis_data=$(cat $tmp_dir/genesis.json   | jq -c '.alloc    += '"$allocation")
    chainspec_data=$(cat $tmp_dir/chainspec.json | jq -c '.accounts += '"$allocation")
    besu_data=$(cat $tmp_dir/besu.json      | jq -c '.alloc    += '"$allocation")

    echo $genesis_data > $tmp_dir/genesis.json
    echo $chainspec_data > $tmp_dir/chainspec.json
    echo $besu_data > $tmp_dir/besu.json
}

genesis_add_system_contracts() {
    tmp_dir=$1
    system_contracts=$(cat /apps/el-gen/system-contracts.yaml | jq -c)

    echo "Adding system contracts"
    echo "$system_contracts"

    # add deposit contract
    genesis_add_allocation $tmp_dir "$DEPOSIT_CONTRACT_ADDRESS" $(echo "$system_contracts" | jq -c '.deposit')

    if [ "$DENEB_FORK_EPOCH" -lt "18446744073709551615" ]; then
        # EIP-4788: Beacon block root in the EVM
        genesis_add_allocation $tmp_dir $(echo "$system_contracts" | jq -c '.eip4788_address') $(echo "$system_contracts" | jq -c '.eip4788')
    fi

    if [ "$ELECTRA_FORK_EPOCH" -lt "18446744073709551615" ]; then
        # EIP-2935: Serve historical block hashes from state
        genesis_add_allocation $tmp_dir $(echo "$system_contracts" | jq -c '.eip2935_address') $(echo "$system_contracts" | jq -c '.eip2935')

        # EIP-7002: Execution layer triggerable withdrawals
        genesis_add_allocation $tmp_dir $(echo "$system_contracts" | jq -c '.eip7002_address') $(echo "$system_contracts" | jq -c '.eip7002')

        # EIP-7251: Increase the MAX_EFFECTIVE_BALANCE
        genesis_add_allocation $tmp_dir $(echo "$system_contracts" | jq -c '.eip7251_address') $(echo "$system_contracts" | jq -c '.eip7251')
    fi
}

genesis_add_pre_bellatrix() {
    tmp_dir=$1
    genesis_data=$(cat $tmp_dir/genesis.json)
    chainspec_data=$(cat $tmp_dir/chainspec.json)
    besu_data=$(cat $tmp_dir/besu.json)
    
    echo "Adding pre-bellatrix genesis properties (TODO)"

    # genesis.json
    # "mergeNetsplitBlock": 1735371,
    # "terminalTotalDifficulty": 17000000000000000,

    # chainspec.json
    # "terminalTotalDifficulty": "0x3c6568f12e8000",
    # "mergeForkIdTransition": "0x1A7ACB",

    # besu.json
    # "mergeForkBlock": 1735371,
    # "terminalTotalDifficulty": 17000000000000000,
}

genesis_add_post_bellatrix() {
    tmp_dir=$1
    genesis_data=$(cat $tmp_dir/genesis.json)
    chainspec_data=$(cat $tmp_dir/chainspec.json)
    besu_data=$(cat $tmp_dir/besu.json)
    
    echo "Adding bellatrix genesis properties"

    # genesis.json
    # "mergeNetsplitBlock": 0
    # "terminalTotalDifficulty": 0
    # "terminalTotalDifficultyPassed": true
    genesis_data=$(echo $genesis_data | jq '.config += {"mergeNetsplitBlock": 0, "terminalTotalDifficulty": 0, "terminalTotalDifficultyPassed": true}')

    # chainspec.json
    # "mergeForkIdTransition": "0x0"
    # "terminalTotalDifficulty":"0x0"
    chainspec_data=$(echo $chainspec_data | jq '.params += {"mergeForkIdTransition": "0x0", "terminalTotalDifficulty":"0x0"}')

    # besu.json
    # "preMergeForkBlock": 0
    # "terminalTotalDifficulty": 0
    # "ethash": {}
    besu_data=$(echo $besu_data | jq '. += {"preMergeForkBlock": 0, "terminalTotalDifficulty": 0, "ethash": {}}')

    echo $genesis_data > $tmp_dir/genesis.json
    echo $chainspec_data > $tmp_dir/chainspec.json
    echo $besu_data > $tmp_dir/besu.json
}

# add capella fork properties
genesis_add_capella() {
    tmp_dir=$1
    genesis_data=$(cat $tmp_dir/genesis.json)
    chainspec_data=$(cat $tmp_dir/chainspec.json)
    besu_data=$(cat $tmp_dir/besu.json)
    
    echo "Adding capella genesis properties"
    shanghai_time=$(genesis_get_activation_time $CAPELLA_FORK_EPOCH)
    shanghai_time_hex="0x$(printf "%x" $shanghai_time)"

    # genesis.json
    # "shanghaiTime": 123456
    genesis_data=$(echo $genesis_data | jq '.config += {"shanghaiTime": '"$shanghai_time"'}')

    # chainspec.json
    # "eip4895TransitionTimestamp": "0x123456"
    # "eip3855TransitionTimestamp": "0x123456"
    # "eip3651TransitionTimestamp": "0x123456"
    # "eip3860TransitionTimestamp": "0x123456"
    chainspec_data=$(echo $chainspec_data | jq '.params += {"eip4895TransitionTimestamp": "'$shanghai_time_hex'", "eip3855TransitionTimestamp": "'$shanghai_time_hex'", "eip3651TransitionTimestamp": "'$shanghai_time_hex'", "eip3860TransitionTimestamp": "'$shanghai_time_hex'"}')

    # besu.json
    # "shanghaiTime": 123456
    besu_data=$(echo $besu_data | jq '.config += {"shanghaiTime": '"$shanghai_time"'}')

    echo $genesis_data > $tmp_dir/genesis.json
    echo $chainspec_data > $tmp_dir/chainspec.json
    echo $besu_data > $tmp_dir/besu.json
}

# add deneb fork properties
genesis_add_deneb() {
    tmp_dir=$1
    genesis_data=$(cat $tmp_dir/genesis.json)
    chainspec_data=$(cat $tmp_dir/chainspec.json)
    besu_data=$(cat $tmp_dir/besu.json)
    
    echo "Adding deneb genesis properties"
    cancun_time=$(genesis_get_activation_time $DENEB_FORK_EPOCH)
    cancun_time_hex="0x$(printf "%x" $cancun_time)"

    # genesis.json
    # "cancunTime": 123456
    genesis_data=$(echo $genesis_data | jq '.config += {"cancunTime": '"$cancun_time"'}')

    # chainspec.json
    # "eip4844TransitionTimestamp": "0x123456",
    # "eip4788TransitionTimestamp": "0x123456",
    # "eip1153TransitionTimestamp": "0x123456",
    # "eip5656TransitionTimestamp": "0x123456",
    # "eip6780TransitionTimestamp": "0x123456",
    chainspec_data=$(echo $chainspec_data | jq '.params += {"eip4844TransitionTimestamp": "'$cancun_time_hex'", "eip4788TransitionTimestamp": "'$cancun_time_hex'", "eip1153TransitionTimestamp": "'$cancun_time_hex'", "eip5656TransitionTimestamp": "'$cancun_time_hex'", "eip6780TransitionTimestamp": "'$cancun_time_hex'"}')

    # besu.json
    # "cancunTime": 123456
    besu_data=$(echo $besu_data | jq '.config += {"cancunTime": '"$cancun_time"'}')

    echo $genesis_data > $tmp_dir/genesis.json
    echo $chainspec_data > $tmp_dir/chainspec.json
    echo $besu_data > $tmp_dir/besu.json
}

# add electra fork properties
genesis_add_electra() {
    tmp_dir=$1
    genesis_data=$(cat $tmp_dir/genesis.json)
    chainspec_data=$(cat $tmp_dir/chainspec.json)
    besu_data=$(cat $tmp_dir/besu.json)
    
    echo "Adding electra genesis properties"
    prague_time=$(genesis_get_activation_time $ELECTRA_FORK_EPOCH)
    prague_time_hex="0x$(printf "%x" $prague_time)"

    # genesis.json
    # "depositContractAddress": "0x4242424242424242424242424242424242424242"
    # "pragueTime": 123456
    genesis_data=$(echo $genesis_data | jq '.config += {"depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'", "pragueTime": '"$prague_time"'}')

    # chainspec.json
    # "depositContractAddress": "0x4242424242424242424242424242424242424242"
    # "eip2537TransitionTimestamp": "0x123456"
    # "eip2935TransitionTimestamp": "0x123456"
    # "eip6110TransitionTimestamp": "0x123456"
    # "eip7002TransitionTimestamp": "0x123456"
    # "eip7251TransitionTimestamp": "0x123456"
    # "eip7702TransitionTimestamp": "0x123456"
    chainspec_data=$(echo $chainspec_data | jq '.params += {"depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'", "eip2537TransitionTimestamp": "'$prague_time_hex'", "eip2935TransitionTimestamp": "'$prague_time_hex'", "eip6110TransitionTimestamp": "'$prague_time_hex'", "eip7002TransitionTimestamp": "'$prague_time_hex'", "eip7251TransitionTimestamp": "'$prague_time_hex'", "eip7702TransitionTimestamp": "'$prague_time_hex'"}')

    # besu.json
    # "depositContractAddress": "0x4242424242424242424242424242424242424242"
    # "pragueTime": 123456
    besu_data=$(echo $besu_data | jq '.config += {"depositContractAddress": "'"$DEPOSIT_CONTRACT_ADDRESS"'", "pragueTime": '"$prague_time"'}')

    echo $genesis_data > $tmp_dir/genesis.json
    echo $chainspec_data > $tmp_dir/chainspec.json
    echo $besu_data > $tmp_dir/besu.json
}

# add fulu fork properties
genesis_add_fulu() {
    tmp_dir=$1
    genesis_data=$(cat $tmp_dir/genesis.json)
    chainspec_data=$(cat $tmp_dir/chainspec.json)
    besu_data=$(cat $tmp_dir/besu.json)
    
    echo "Adding fulu genesis properties"
    osaka_time=$(genesis_get_activation_time $FULU_FORK_EPOCH)
    osaka_time_hex="0x$(printf "%x" $osaka_time)"

    # genesis.json
    # "osakaTime": 123456
    genesis_data=$(echo $genesis_data | jq '.config += {"osakaTime": '"$osaka_time"'}')

    # chainspec.json
    # "eip7692TransitionTimestamp": "0x123456"
    chainspec_data=$(echo $chainspec_data | jq '.params += {"eip7692TransitionTimestamp": "'$osaka_time_hex'"}')

    # besu.json
    # "osakaTime": 123456
    besu_data=$(echo $besu_data | jq '.config += {"osakaTime": '"$osaka_time"'}')

    echo $genesis_data > $tmp_dir/genesis.json
    echo $chainspec_data > $tmp_dir/chainspec.json
    echo $besu_data > $tmp_dir/besu.json
}
