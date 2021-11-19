# ethereum-genesis-generator

Create a ethereum consensus/execution layer testnet genesis and expose it via a webserver for testing purposes.

### Examples

Running with the default configuration. Check the [config-example](config-example) directory.

```sh
docker run -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 skylenet/ethereum-genesis-generator:latest all # Create EL+CL genesis
docker run -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 skylenet/ethereum-genesis-generator:latest cl  # Just CL
docker run -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 skylenet/ethereum-genesis-generator:latest el  # Just EL
```

You can overwrite configuration files and apply your own by using volume mounts:

```sh
# Overwriting the config files and generating the EL and CL genesis
docker run -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 \
  -v $PWD/cl-config.yaml:/config/cl/config.yaml \
  -v $PWD/cl-mnemonics.yaml:/config/cl/mnemonics.yaml \
  -v $PWD/el-config.yaml:/config/el/genesis-config.yaml \
  skylenet/ethereum-genesis-generator:latest all

# Just creating the EL genesis
docker run -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 \
  -v $PWD/el-config.yaml:/config/el/genesis-config.yaml \
  skylenet/ethereum-genesis-generator:latest el

# Just creating the CL genesis
docker run -it -u $UID -v $PWD/data:/data -p 127.0.0.1:8000:8000 \
  -v $PWD/cl-config.yaml:/config/cl/config.yaml \
  -v $PWD/cl-mnemonics.yaml:/config/cl/mnemonics.yaml \
  skylenet/ethereum-genesis-generator:latest cl
```

After that, access `http://localhost:8000` on your browser to see the genesis files

### Environment variables

Name | Default | Description
---- |-------- | ----
SERVER_PORT | 8000 | Web server port
CL_TIMESTAMP_DELAY_SECONDS | 300 | The consensus layer genesis timestamp will be the current time + CL_TIMESTAMP_DELAY_SECONDS

Besides that, you can also use ENV vars in your configuration files. These will be replaced during runtime.

### Available tools within the image

Name | Source
---- | ----
eth2-testnet-genesis | https://github.com/protolambda/eth2-testnet-genesis
eth2-val-tools | https://github.com/protolambda/eth2-val-tools
el-gen | [apps/el-gen](apps/el-gen)
