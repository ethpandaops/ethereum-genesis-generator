# ethereum-genesis-generator

Create a ethereum consensus/execution layer testnet genesis and optionally expose it via a web server for testing purposes.

### Examples

Create a new file with your custom configuration in `./config/values.env`. You can use the [defaults.env](defaults/defaults.env) file as a template.

```sh
# Create the output directory
mkdir output

# Overwriting the config files and generating the EL and CL genesis
docker run --rm -it -u $UID -v $PWD/output:/data \
  -v $PWD/config/values.env:/config/values.env \
  ethpandaops/ethereum-genesis-generator:master all

# Just creating the EL genesis
docker run --rm -it -u $UID -v $PWD/output:/data \
  -v $PWD/config/values.env:/config/values.env \
  ethpandaops/ethereum-genesis-generator:master el

# Just creating the CL genesis
docker run --rm -it -u $UID -v $PWD/output:/data \
  -v $PWD/config/values.env:/config/values.env \
  ethpandaops/ethereum-genesis-generator:master cl
```
### Environment variables

Name           | Default | Description
-------------- |-------- | ----
SERVER_ENABLED | false   | Enable a web server that will serve the generated files
SERVER_PORT    | 8000    | Web server port

Besides that, you can also use ENV vars in your configuration files. One way of doing this is via the [values.env](config-example/values.env) configuration file. These will be replaced during runtime.

### Validator withdrawal credential types

The `WITHDRAWAL_TYPE` environment variable controls the withdrawal credential prefix for genesis validators. The `WITHDRAWAL_ADDRESS` must be set for all types except `0x00`.

Type | Name | Description
---- | ---- | -----------
`0x00` | BLS withdrawal | Credentials derived from the validator's BLS withdrawal key. No execution address required. Validators must rotate to `0x01` or higher before withdrawals can be processed.
`0x01` | Execution withdrawal | Credentials pointing to an execution layer address. Enables partial and full withdrawals to the specified address. Effective balance is capped at 32 ETH.
`0x02` | Compounding | Like `0x01` but enables reward compounding. Effective balance can grow up to `MAX_EFFECTIVE_BALANCE_ELECTRA` (2048 ETH). Requires Electra or later.
`0x03` | Builder | Identifies a builder validator (EIP-7732 ePBS). Same address structure as `0x01`/`0x02`. Builders participate in the decentralized block auction mechanism. Requires EIP-7732 or later.

### Shadow Fork
If shadow fork from file is the preferred option, then please ensure the latest block `json` response is collected along with
transactions. This can be done with the below call for example:
```sh
curl -H "Content-Type: application/json" --data-raw '{ "jsonrpc":"2.0","method":"eth_getBlockByNumber", "params":[ "latest", true ], "id":1 }' localhost:8545
```

### Release line explanation
v1 -> bellatrix genesis state
v2 -> capella genesis state
v3 -> deneb genesis state
v4 -> electra genesis state
v5 -> fulu genesis state
v6 -> gloas genesis state
verkle-gen -> verkle genesis state

### Available tools within the image

Name | Source
---- | ----
eth-beacon-genesis | https://github.com/ethpandaops/eth-beacon-genesis
eth2-val-tools | https://github.com/protolambda/eth2-val-tools
el-gen | [apps/el-gen](apps/el-gen)
