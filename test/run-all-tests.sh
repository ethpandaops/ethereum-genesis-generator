#!/bin/bash

set -e

# Fails the test run when a value does not match the expected one
assert_eq() {
    local name=$1 actual=$2 expected=$3
    if [ "$actual" != "$expected" ]; then
        echo "❌ $name: expected '$expected', got '$actual'"
        exit 1
    fi
    echo "✅ $name: $actual"
}

# Creates a fresh, never-used output dir, so a stale genesis.json from a
# previous case (e.g. lagging bind mount sync on Docker Desktop) can't make
# the generator skip EL genesis
fresh_output() {
    local dir
    dir=$(mktemp -d "$PWD/output/$1.XXXXXX")
    chmod 777 "$dir"
    echo "$dir"
}

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

echo "=== Test Case 5: FRAMES_ENABLED (Heze off on CL, bogota active on EL) ==="
echo "Expected: config.yaml HEZE_FORK_EPOCH: 18446744073709551615,"
echo "          genesis.json has a non-null bogotaTime, the EIP-8141 expiry verifier"
echo "          and the EIP-8250 nonce manager"
rm -rf output/metadata output/parsed
docker run -u 1000:1000 --rm -v $PWD/output:/data -v $PWD/test-cases/case5-frames-enabled.env:/config/values.env ethpandaops/ethereum-genesis-generator:master all > /dev/null 2>&1
echo "Result:"
grep "^HEZE_FORK_EPOCH:" output/metadata/config.yaml
jq -c '{bogotaTime: .config.bogotaTime}' output/metadata/genesis.json
jq -c '{expiryVerifier: .alloc["0x81413f0cF12e9b6a49B1D0439E081c577D57FfFf"]}' output/metadata/genesis.json
jq -c '{nonceManager: .alloc["0x8250968C12e01A19d6F667b9B2F3b3A4d0e51cB7"]}' output/metadata/genesis.json
echo ""

echo "=== Test Case 6: Heze shorter slots, then a BPO ==="
echo "Expected: bogotaTime unaffected by the slot change at its own epoch,"
echo "          bpo1Time counts 2 epochs at 12s and 2 epochs at 6s"
out=$(fresh_output case6)
docker run -u 1000:1000 --rm -v $out:/data -v $PWD/test-cases/case6-shorter-slots.env:/config/values.env ethpandaops/ethereum-genesis-generator:master all > /dev/null 2>&1
echo "Result:"
assert_eq "amsterdamTime" "$(jq -r '.config.amsterdamTime' $out/metadata/genesis.json)" "404"
assert_eq "bogotaTime" "$(jq -r '.config.bogotaTime' $out/metadata/genesis.json)" "788"
assert_eq "bpo1Time" "$(jq -r '.config.bpo1Time' $out/metadata/genesis.json)" "1172"
assert_eq "SLOT_DURATION_MS" "$(grep '^SLOT_DURATION_MS:' $out/metadata/config.yaml)" "SLOT_DURATION_MS: 12000"
assert_eq "HEZE_FORK_EPOCH" "$(grep '^HEZE_FORK_EPOCH:' $out/metadata/config.yaml)" "HEZE_FORK_EPOCH: 2"
assert_eq "SLOT_DURATION_MS_HEZE" "$(grep '^SLOT_DURATION_MS_HEZE:' $out/metadata/config.yaml)" "SLOT_DURATION_MS_HEZE: 6000"
rm -rf "$out"
echo ""

echo "=== Test Case 7: Heze with the default 10s slot duration ==="
echo "Expected: BPO times count 12s slots before Heze and 10s slots after"
out=$(fresh_output case7)
docker run -u 1000:1000 --rm -v $out:/data -v $PWD/test-cases/case7-default-heze-slot-duration.env:/config/values.env ethpandaops/ethereum-genesis-generator:master all > /dev/null 2>&1
echo "Result:"
assert_eq "bpo1Time" "$(jq -r '.config.bpo1Time' $out/metadata/genesis.json)" "1108"
assert_eq "bpo2Time" "$(jq -r '.config.bpo2Time' $out/metadata/genesis.json)" "2068"
rm -rf "$out"
echo ""

echo "=== Test Case 8: GAS_LIMIT_SCHEDULE with a genesis entry (unsorted input) ==="
echo "Expected: epoch 0 entry kept, schedule sorted by epoch"
out=$(fresh_output case8)
docker run -u 1000:1000 --rm -v $out:/data -v $PWD/test-cases/case8-gas-limit-schedule-genesis.env:/config/values.env ethpandaops/ethereum-genesis-generator:master all > /dev/null 2>&1
echo "Result:"
assert_eq "GAS_LIMIT_SCHEDULE" "$(grep -A4 '^GAS_LIMIT_SCHEDULE:' $out/metadata/config.yaml | tr -s ' \n' ' ')" \
    "GAS_LIMIT_SCHEDULE: - EPOCH: 0 GAS_LIMIT: 60000000 - EPOCH: 4 GAS_LIMIT: 100000000 "
rm -rf "$out"
echo ""

echo "=== Test Case 9: default SLOT_DURATION_MS_HEZE (mainnet) ==="
echo "Expected: 10000 ms, no SLOT_DURATION_SCHEDULE"
out=$(fresh_output case9)
docker run -u 1000:1000 --rm -v $out:/data -v $PWD/test-cases/case9-default-heze-slot-duration.env:/config/values.env ethpandaops/ethereum-genesis-generator:master all > /dev/null 2>&1
echo "Result:"
assert_eq "SLOT_DURATION_MS_HEZE" "$(grep '^SLOT_DURATION_MS_HEZE:' $out/metadata/config.yaml)" "SLOT_DURATION_MS_HEZE: 10000"
assert_eq "SLOT_DURATION_SCHEDULE" "$(grep -c '^SLOT_DURATION_SCHEDULE:' $out/metadata/config.yaml || true)" "0"
rm -rf "$out"
echo ""

echo "=== Test Case 10: default SLOT_DURATION_MS_HEZE (minimal) ==="
echo "Expected: 5000 ms"
out=$(fresh_output case10)
docker run -u 1000:1000 --rm -v $out:/data -v $PWD/test-cases/case10-default-heze-slot-duration-minimal.env:/config/values.env ethpandaops/ethereum-genesis-generator:master all > /dev/null 2>&1
echo "Result:"
assert_eq "SLOT_DURATION_MS_HEZE" "$(grep '^SLOT_DURATION_MS_HEZE:' $out/metadata/config.yaml)" "SLOT_DURATION_MS_HEZE: 5000"
rm -rf "$out"
echo ""

echo "=== Test Case 11: SLOT_DURATION_MS override, Heze not scheduled (mainnet) ==="
echo "Expected: fork times use 6s slots"
out=$(fresh_output case11)
docker run -u 1000:1000 --rm -v $out:/data -v $PWD/test-cases/case11-slot-duration-override.env:/config/values.env ethpandaops/ethereum-genesis-generator:master all > /dev/null 2>&1
echo "Result:"
assert_eq "SLOT_DURATION_MS" "$(grep '^SLOT_DURATION_MS:' $out/metadata/config.yaml)" "SLOT_DURATION_MS: 6000"
assert_eq "amsterdamTime" "$(jq -r '.config.amsterdamTime' $out/metadata/genesis.json)" "12308"
rm -rf "$out"
echo ""
echo "================================"
echo "✅ All tests complete!"
echo "================================"
