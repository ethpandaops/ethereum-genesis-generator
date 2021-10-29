# ethereum-genesis-cl

Create a ethereum consensus layer testnet genesis and expose it via a webserver for testing purposes

```sh
# Running with a default config (Check the config-example directory)
docker run -it -v $PWD/data:/data -p 127.0.0.1:8000:8000 skylenet/ethereum-genesis-cl:latest

# Overwriting the config files
docker run -it -v $PWD/data:/data -p 127.0.0.1:8000:8000 \
  -v $PWD/yourconfig.yaml:/config/config.yaml \
  -v $PWD/yourmnemonics.yaml:/config/mnemonics.yaml \
  skylenet/ethereum-genesis-cl:latest
```


### Available tools within the image

Name | Source
---- | ----
eth2-testnet-genesis | https://github.com/protolambda/eth2-testnet-genesis
eth2-val-tools | https://github.com/protolambda/eth2-val-tools
