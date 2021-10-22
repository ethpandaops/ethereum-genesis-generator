# ethereum-genesis-cl
Create a ethereum consensus layer testnet genesis and expose it via a webserver for testing purposes

```sh
docker build -t skylenet/ethereum-genesis-cl:latest .


docker run -it -v $PWD/data:/data -p 127.0.0.1:8000:8000 ethereum-genesis-cl:latest
```
