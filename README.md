# ethereum-genesis-generator

Create a ethereum consensus/execution layer testnet genesis and optionally expose it via a web server for testing purposes.

### Examples

You can provide your own configuration directory. Have a look at the example in [`config-example`](config-example).

```sh
# Create the output directory
mkdir output

# Overwriting the config files and generating the EL and CL genesis
docker run --rm -it -u $UID -v $PWD/output:/data \
  -v $PWD/config-example:/config \
  ethpandaops/ethereum-genesis-generator:latest all

# Just creating the EL genesis
docker run --rm -it -u $UID -v $PWD/output:/data \
  -v $PWD/config-example:/config \
  ethpandaops/ethereum-genesis-generator:latest el

# Just creating the CL genesis
docker run --rm -it -u $UID -v $PWD/output:/data \
  -v $PWD/config-example:/config \
  ethpandaops/ethereum-genesis-generator:latest cl
```
### Environment variables

Name           | Default | Description
-------------- |-------- | ----
SERVER_ENABLED | false   | Enable a web server that will serve the generated files
SERVER_PORT    | 8000    | Web server port

Besides that, you can also use ENV vars in your configuration files. One way of doing this is via the [values.env](config-example/values.env) configuration file. These will be replaced during runtime.

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
verkle-gen -> verkle genesis state

### Available tools within the image

Name | Source
---- | ----
eth2-testnet-genesis | https://github.com/protolambda/eth2-testnet-genesis
eth2-val-tools | https://github.com/protolambda/eth2-val-tools
zcli | https://github.com/protolambda/zcli
el-gen | [apps/el-gen](apps/el-gen)
