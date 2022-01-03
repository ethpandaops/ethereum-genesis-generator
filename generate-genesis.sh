#!/usr/bin/env bash
# 2021-07-08 WATERMARK, DO NOT REMOVE - This script was generated from the Kurtosis Bash script template

set -euo pipefail   # Bash "strict mode"
script_dirpath="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# ==================================================================================================
#                                             Constants
# ==================================================================================================
CL_ETH1_BLOCK="0x0000000000000000000000000000000000000000000000000000000000000000"
GETH_GENESIS_CONFIG_FILENAME="genesis-config.yaml"
GETH_GENESIS_JSON_FILENAME="geth.json"
GETH_CHAINSPEC_JSON_FILENAME="chainspec.json"

CL_GENESIS_CONFIG_FILENAME="config.yaml"
CL_MNEMONICS_CONFIG_FILENAME="mnemonics.yaml"
DEPOSIT_CONTRACT_FILENAME="deposit_contract.txt"
DEPLOY_BLOCK_FILENAME="deploy_block.txt"
TRANCHES_DIRNAME="tranches"
CL_GENESIS_FILENAME="genesis.ssz"

DEPOSIT_CONTRACT_ADDRESS_PROPERTY_NAME="DEPOSIT_CONTRACT_ADDRESS"
CL_GENESIS_TIMESTAMP_PROPERTY_NAME="MIN_GENESIS_TIME"

# ==================================================================================================
#                                       Arg Parsing & Validation
# ==================================================================================================
show_helptext_and_exit() {
    echo "Usage: $(basename "${0}") config_dirpath output_dirpath"
    echo ""
    echo "  config_dirpath      The directory containing genesis config information, used to generate the output"
    echo "  output_dirpath      The output directory where generated genesis information will be generated"
    echo ""
    exit 1  # Exit with an error so that if this is accidentally called by CI, the script will fail
}

config_dirpath="${1:-}"
output_dirpath="${2:-}"

if ! [ -d "${config_dirpath}" ]; then
    echo "Error: config dirpath '${config_dirpath}' isn't a valid directory" >&2
    show_helptext_and_exit
fi
if [ -z "${output_dirpath}" ]; then
    echo "Error: output dirpath is empty" >&2
    show_helptext_and_exit
fi
if [ -e "${output_dirpath}" ]; then
    echo "Error: output directory '${output_dirpath}' already exists" >&2
    show_helptext_and_exit
fi



# ==================================================================================================
#                                             Main Logic
# ==================================================================================================
# Generate Geth config
el_output_dirpath="${output_dirpath}/el"
if ! mkdir -p "${el_output_dirpath}"; then
    echo "Error: Couldn't create Geth output genesis directory '${el_output_dirpath}'" >&2
    exit 1
fi
geth_genesis_json_filepath="${el_output_dirpath}/${GETH_GENESIS_JSON_FILENAME}"
geth_chainspec_json_filepath="${el_output_dirpath}/${GETH_CHAINSPEC_JSON_FILENAME}"

el_config_dirpath="${config_dirpath}/el"
geth_genesis_config_filepath="${el_config_dirpath}/${GETH_GENESIS_CONFIG_FILENAME}"
if ! python3 /apps/el-gen/genesis_geth.py "${geth_genesis_config_filepath}" > "${geth_genesis_json_filepath}"; then
    echo "Error: An error occurred generating the Geth genesis JSON file" >&2
    exit 1
fi
if ! python3 /apps/el-gen/genesis_chainspec.py "${geth_genesis_config_filepath}" > "${geth_chainspec_json_filepath}"; then
    echo "Error: An error occurred generating the Geth chainspec JSON file" >&2
    exit 1
fi

# Generate CL config
cl_output_dirpath="${output_dirpath}/cl"
if ! mkdir -p "${cl_output_dirpath}"; then
    echo "Error: Couldn't create CL output genesis directory '${cl_output_dirpath}'" >&2
    exit 1
fi
tranches_dirpath="${cl_output_dirpath}/${TRANCHES_DIRNAME}"
cl_genesis_filepath="${cl_output_dirpath}/${CL_GENESIS_FILENAME}"
deposit_contract_filepath="${cl_output_dirpath}/${DEPOSIT_CONTRACT_FILENAME}"
deploy_block_filepath="${cl_output_dirpath}/${DEPLOY_BLOCK_FILENAME}"

cl_config_dirpath="${config_dirpath}/cl"
cl_genesis_config_filepath="${cl_config_dirpath}/${CL_GENESIS_CONFIG_FILENAME}"
cl_mnemonics_config_filepath="${cl_config_dirpath}/${CL_MNEMONICS_CONFIG_FILENAME}"

# Create deposit_contract.txt and deploy_block.txt
grep "${DEPOSIT_CONTRACT_ADDRESS_PROPERTY_NAME}" "${cl_genesis_config_filepath}" | cut -d " " -f2 > "${deposit_contract_filepath}"
echo "0" > "${deploy_block_filepath}"

genesis_timestamp_property_lines="$(grep "${CL_GENESIS_TIMESTAMP_PROPERTY_NAME}" "${cl_genesis_config_filepath}")"
if ! num_genesis_timestamp_properties="$(echo "${genesis_timestamp_property_lines}" | wc -l)"; then
    echo "Error: An error occurred getting the number of lines with the timestamp property '${CL_GENESIS_TIMESTAMP_PROPERTY_NAME}' in CL genesis config file '${cl_genesis_config_filepath}'" >&2
    exit 1
fi
if [ "${num_genesis_timestamp_properties}" -ne 1 ]; then
    echo "Error: Expected exactly 1 line with CL genesis config property '${CL_GENESIS_TIMESTAMP_PROPERTY_NAME}' but got ${num_genesis_timestamp_properties}" >&2
    exit 1
fi
if ! genesis_timestamp="$(echo "${genesis_timestamp_property_lines}" | awk '{print $2}')"; then
    echo "Error: An error occurred extracting the genesis timestamp from line '${genesis_timestamp_property_lines}'" >&2
    exit 1
fi

if ! cp "${cl_genesis_config_filepath}" "${cl_output_dirpath}"/; then
    echo "Error: Couldn't copy CL genesis config file '${cl_genesis_config_filepath}' to CL genesis output directory '${cl_output_dirpath}'" >&2
    exit 1
fi

# Generate CL genesis info
if ! /usr/local/bin/eth2-testnet-genesis phase0 \
        --config "${cl_genesis_config_filepath}" \
        --eth1-block "${CL_ETH1_BLOCK}" \
        --mnemonics "${cl_mnemonics_config_filepath}" \
        --timestamp "${genesis_timestamp}" \
        --tranches-dir "${tranches_dirpath}" \
        --state-output "${cl_genesis_filepath}"; then
    echo "Error: An error occurred generating the CL genesis information" >&2
    exit 1
fi
