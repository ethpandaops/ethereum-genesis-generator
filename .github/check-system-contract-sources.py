#!/usr/bin/env python3
"""
Checks the vendored system contracts in apps/el-gen/system-contracts.yaml against
the upstream pinned by each `<name>_source` entry.

  ethereum/EIPs, with `after`:  the runtime code is the hex following that marker
  ethereum/EIPs, no `after`:    a JSON asset that must equal the whole entry
  ethereum/sys-asm:             geas source, built with the geas version its Makefile pins

To follow an upstream change, bump `ref` and run with --update.
"""

import argparse
import io
import json
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

import yaml

SYSTEM_CONTRACTS = "apps/el-gen/system-contracts.yaml"


def fetch(url: str) -> bytes:
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return response.read()
        except OSError:
            if attempt == 4:
                raise
            time.sleep(2**attempt)


def from_eips(src: dict):
    text = fetch(f"https://raw.githubusercontent.com/{src['repo']}/{src['ref']}/{src['path']}").decode()
    if "after" not in src:
        return json.loads(text)
    match = re.compile(re.escape(src["after"]) + r"(?:.*?0x)??([0-9a-fA-F]+)", re.S).search(text)
    if not match:
        raise ValueError(f"marker {src['after']!r} not found in {src['path']}@{src['ref']}")
    return "0x" + match.group(1).lower()


def from_sys_asm(src: dict) -> str:
    tarball = fetch(f"https://codeload.github.com/{src['repo']}/tar.gz/{src['ref']}")
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(fileobj=io.BytesIO(tarball)) as tar:
            root = f"{tmp}/{tar.getnames()[0].split('/')[0]}"
            tar.extractall(tmp, filter="data")
        with open(f"{root}/Makefile") as f:
            geas = re.search(r"^GEAS_VERSION\s*\?=\s*(\S+)", f.read(), re.M).group(1)
        code = subprocess.run(
            ["go", "run", f"github.com/fjl/geas/cmd/geas@v{geas}", "-a", "-no-nl", src["path"]],
            cwd=root, check=True, capture_output=True, text=True,
        ).stdout.strip()
    return "0x" + code.lower().removeprefix("0x")


def upstream(src: dict):
    return from_sys_asm(src) if src["repo"] == "ethereum/sys-asm" else from_eips(src)


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument("--update", action="store_true", help="rewrite vendored values from their sources")
    args = parser.parse_args()

    with open(SYSTEM_CONTRACTS) as f:
        text = f.read()
    contracts = yaml.safe_load(text)

    failures = 0
    for key, src in contracts.items():
        if not key.endswith("_source"):
            continue
        name = key.removesuffix("_source")
        theirs = upstream(src)
        if isinstance(theirs, str):
            ours = contracts[name]["code"]
            if ours.lower() == theirs:
                print(f"OK       {name}")
                continue
            text = text.replace(ours, theirs)
        else:
            if contracts[name] == theirs:
                print(f"OK       {name}")
                continue
            block = re.compile(rf"^{name}: \{{.*?^\}}\n", re.M | re.S)
            text = block.sub(lambda _: f"{name}: {json.dumps(theirs, indent=2)}\n", text)
        print(f"{'UPDATED' if args.update else 'MISMATCH'} {name}: differs from {src['repo']}@{src['ref'][:10]} {src['path']}")
        failures += 1

    if args.update:
        with open(SYSTEM_CONTRACTS, "w") as f:
            f.write(text)
    elif failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
