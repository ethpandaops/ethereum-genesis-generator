#!/bin/bash

set -e

echo "================================"
echo "Building docker image with tag :master"
echo "================================"
echo ""
docker build -t ethpandaops/ethereum-genesis-generator:master "$(dirname "$0")/.."

echo "================================"
echo "Running All BPO Tests"
echo "================================"
echo ""

mkdir -p output

echo "=== Test Case 1: Osaka only ==="
echo "Expected: no osaka entry in blobSchedule (cancun and prague only)"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case1-osaka-only.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule' output/metadata/genesis.json
echo ""

echo "=== Test Case 2: Osaka → BPO_1 → Amsterdam ==="
echo "Expected: bpo1: 8/12 (explicit), no amsterdam entry"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case2-osaka-bpo-amsterdam.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule | {bpo1}' output/metadata/genesis.json
echo ""

echo "=== Test Case 3: Osaka → Amsterdam → BPO_1 ==="
echo "Expected: bpo1: 12/18 (explicit), no amsterdam entry"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case3-osaka-amsterdam-bpo.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule | {bpo1}' output/metadata/genesis.json
echo ""

echo "=== Test Case 4: Multiple BPOs ==="
echo "Expected: bpo1: 8/12, bpo2: 9/14, bpo3: 15/24 (all explicit),"
echo "          no osaka/amsterdam entries"
rm -rf output/metadata
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case4-multiple-bpos.env:/config/values.env ethpandaops/ethereum-genesis-generator:master el > /dev/null 2>&1
echo "Result:"
jq -c '.config.blobSchedule | {bpo1, bpo2, bpo3}' output/metadata/genesis.json
echo ""

echo ""
echo "================================"
echo "✅ All tests complete!"
echo "================================"
