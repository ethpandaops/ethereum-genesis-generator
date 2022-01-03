# TBD
### Fixes
* No longer adds 300s to the CL genesis timestamp

### Changes
* Made Docker image more compatible with Kurtosis

# 0.1.3
### Changes
* Don't start a Python HTTP server with the entrypoint script - just do the genesis generation

# 0.1.2
* Empty commit to force CircleCI to rebuild the image

# 0.1.1
* Set `terminal total difficulty` property to enable --catalyst option in geth client
* Added Circle CI configuration
* Added `get-docker-image-tag` to automatically generate the Docker image tag
* Added `build` script to build Docker image
* Added `release` script to cut new releases for this repo

# 0.1.0
* Forked from https://github.com/skylenet/ethereum-genesis-generator
