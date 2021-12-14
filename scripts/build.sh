#!/usr/bin/env bash
set -euo pipefail # Bash "strict mode"
script_dirpath="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dirpath="$(dirname "${script_dirpath}")"

# ==================================================================================================
#                                             Constants
# ==================================================================================================
source "${script_dirpath}/_constants.env"

# =============================================================================
#                                 Main Code
# =============================================================================
# Checks if dockerignore file is in the root path
if ! [ -f "${root_dirpath}"/.dockerignore ]; then
  echo "Error: No .dockerignore file found in root '${root_dirpath}'; this is required so Docker caching is enabled and your Docker image builds remain quick" >&2
  exit 1
fi

get_docker_image_tag_script_filepath="${script_dirpath}/${GET_DOCKER_IMAGE_TAG_SCRIPT_FILENAME}"
if ! docker_tag="$(bash "${get_docker_image_tag_script_filepath}")"; then
    echo "Error: Couldn't get the Docker image tag" >&2
    exit 1
fi

# Build Docker image
dockerfile_filepath="${root_dirpath}/Dockerfile"
image_name="${IMAGE_ORG_AND_REPO}:${docker_tag}"
echo "Building Ethereum Genesis Generator into a Docker image named '${image_name}'..."
if ! docker build -t "${image_name}" -f "${dockerfile_filepath}" "${root_dirpath}"; then
  echo "Error: Docker build failed" >&2
  exit 1
fi
echo "Successfully built Docker image '${image_name}' containing the Ethereum Genesis Generator"
