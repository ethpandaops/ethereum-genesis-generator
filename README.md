# ethereum-genesis-generator

Create a ethereum consensus/execution layer testnet genesis and expose it via a webserver for testing purposes.

### Examples

Running with the default configuration. Check the [config-example](config-example) directory.

```sh
mkdir data
docker run --rm -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 ethpandaops/ethereum-genesis-generator:latest all # Create EL+CL genesis
docker run --rm -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 ethpandaops/ethereum-genesis-generator:latest cl  # Just CL
docker run --rm -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 ethpandaops/ethereum-genesis-generator:latest el  # Just EL
```

You can overwrite configuration files. To do so, please update the values in the `config-example/values.env` file
apply it using the docker volume mount:

```sh
# Overwriting the config files and generating the EL and CL genesis
docker run --rm -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 \
  -v $PWD/config-example:/config \
  ethpandaops/ethereum-genesis-generator:latest all

# Just creating the EL genesis
docker run --rm -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 \
  -v $PWD/config-example:/config \
  ethpandaops/ethereum-genesis-generator:latest el

# Just creating the CL genesis
docker run --rm -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 \
  -v $PWD/config-example:/config \
  ethpandaops/ethereum-genesis-generator:latest cl
```

After that, access `http://localhost:8000` on your browser to see the genesis files

### Environment variables

Name | Default | Description
---- |-------- | ----
SERVER_PORT | 8000 | Web server port

Besides that, you can also use ENV vars in your configuration files. One way of doing this is via the [values.env](config-example/values.env) configuration file. These will be replaced during runtime.

### Available tools within the image

Name | Source
---- | ----
eth2-testnet-genesis | https://github.com/protolambda/eth2-testnet-genesis
eth2-val-tools | https://github.com/protolambda/eth2-val-tools
zcli | https://github.com/protolambda/zcli
el-gen | [apps/el-gen](apps/el-gen)

