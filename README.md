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

### Available tools within the image

Name | Source
---- | ----
eth2-testnet-genesis | https://github.com/protolambda/eth2-testnet-genesis
eth2-val-tools | https://github.com/protolambda/eth2-val-tools
zcli | https://github.com/protolambda/zcli
el-gen | [apps/el-gen](apps/el-gen)
