#!/bin/bash

set -e

echo "================================"
echo "Building docker image with tag :master"
echo "================================"
echo ""
docker build -t ethpandaops/ethereum-genesis-generator:master "$(dirname "$0")/.."

echo "================================"
echo "Running All BPO Inheritance Tests"
echo "================================"
echo ""

mkdir -p output

echo "=== Test Case 1: Osaka only ==="
echo "Expected: osaka: target=6, max=9 (inherits from Electra)"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case1-osaka-only.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule.osaka' output/metadata/genesis.json
echo ""

echo "=== Test Case 2: Osaka → BPO_1 → Amsterdam ==="
echo "Expected: bpo1: 8/12 (explicit), amsterdam: 8/12 (inherits from bpo1)"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case2-osaka-bpo-amsterdam.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule | {bpo1, amsterdam}' output/metadata/genesis.json
echo ""

echo "=== Test Case 3: Osaka → Amsterdam → BPO_1 ==="
echo "Expected: amsterdam: 6/9 (inherits from osaka), bpo1: 12/18 (explicit)"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case3-osaka-amsterdam-bpo.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule | {amsterdam, bpo1}' output/metadata/genesis.json
echo ""

echo "=== Test Case 4: Multiple BPOs with inheritance ==="
echo "Expected: osaka: 6/9, bpo1: 8/12 (explicit), bpo2: 9/14,"
echo "          amsterdam: 9/14 (inherits from bpo2), bpo3: 15/24 (explicit)"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case4-multiple-bpos.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule | {osaka, bpo1, bpo2, amsterdam, bpo3}' output/metadata/genesis.json
echo ""

echo ""
echo "================================"
echo "✅ All tests complete!"
echo "================================"
