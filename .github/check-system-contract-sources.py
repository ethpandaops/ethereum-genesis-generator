#!/usr/bin/env python3
"""
Checks apps/el-gen/system-contracts.yaml against the EIPs it comes from.

Every entry except the deposit contract has a `<name>_source` pinning an
ethereum/EIPs commit and file. The runtime code is taken from that file:

  after: <marker>   the hex literal following the marker, which occurs exactly
                    once; a marker ending inside a hex literal (a constructor
                    prefix) selects the rest of that literal
  sys_asm: <path>   built from the ethereum/sys-asm commit the EIP links to,
                    with the geas version that commit's Makefile pins
  (neither)         the file is a JSON asset that must equal the whole entry

`<name>_address`, where present, must appear in the EIP.

To follow an EIP change, bump `ref` and run with --update.
"""

import argparse
import functools
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
UNSOURCED = {"deposit"}


@functools.cache
def fetch(url: str) -> bytes:
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                return response.read()
        except OSError:
            if attempt == 4:
                raise
            time.sleep(2**attempt)


def eip_text(src: dict) -> str:
    return fetch(
        f"https://raw.githubusercontent.com/ethereum/EIPs/{src['ref']}/{src['path']}"
    ).decode()


def after_marker(text: str, marker: str) -> str:
    if text.count(marker) != 1:
        raise ValueError(
            f"marker {marker!r} occurs {text.count(marker)} times, expected once"
        )
    rest = text[text.index(marker) + len(marker) :]
    if re.search(r"0x[0-9a-fA-F]*$", marker):
        match = re.match(r"([0-9a-fA-F]+)", rest)
    else:
        match = re.search(r"0x([0-9a-fA-F]+)", rest)
    if not match:
        raise ValueError(f"no hex literal after marker {marker!r}")
    return "0x" + match.group(1).lower()


def sys_asm(text: str, path: str) -> str:
    commits = set(
        re.findall(r"github\.com/ethereum/sys-asm/(?:tree|blob)/([0-9a-f]{40})", text)
    )
    if len(commits) != 1:
        raise ValueError(f"expected one linked sys-asm commit, found {sorted(commits)}")
    tarball = fetch(
        f"https://codeload.github.com/ethereum/sys-asm/tar.gz/{commits.pop()}"
    )
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(fileobj=io.BytesIO(tarball)) as tar:
            root = f"{tmp}/{tar.getnames()[0].split('/')[0]}"
            tar.extractall(tmp, filter="data")
        with open(f"{root}/Makefile") as f:
            geas = re.search(
                r"^GEAS_VERSION\s*\?=\s*(\S+)", f.read(), re.MULTILINE
            ).group(1)
        code = subprocess.run(
            [
                "go",
                "run",
                f"github.com/fjl/geas/cmd/geas@v{geas}",
                "-a",
                "-no-nl",
                path,
            ],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    return "0x" + code.lower().removeprefix("0x")


def upstream(src: dict, text: str):
    if "after" in src:
        return after_marker(text, src["after"])
    if "sys_asm" in src:
        return sys_asm(text, src["sys_asm"])
    return json.loads(text)


def rewrite(content: str, name: str, theirs) -> str:
    blocks = re.findall(
        rf"^{re.escape(name)}: \{{\n.*?^\}}\n", content, re.MULTILINE | re.DOTALL
    )
    if len(blocks) != 1:
        raise ValueError(
            f"{name}: expected one block in {SYSTEM_CONTRACTS}, found {len(blocks)}"
        )
    if isinstance(theirs, str):
        new = re.sub(r'("code": ")0x[0-9a-fA-F]*"', rf'\g<1>{theirs}"', blocks[0])
    else:
        new = f"{name}: {json.dumps(theirs, indent=2)}\n"
    return content.replace(blocks[0], new)


def main():
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite vendored values from their sources",
    )
    args = parser.parse_args()

    with open(SYSTEM_CONTRACTS) as f:
        content = f.read()
    contracts = yaml.safe_load(content)

    entries = [
        k
        for k, v in contracts.items()
        if isinstance(v, dict) and not k.endswith("_source")
    ]
    failures = [
        f"{name}: no {name}_source"
        for name in entries
        if name not in UNSOURCED and f"{name}_source" not in contracts
    ]

    for name in entries:
        src = contracts.get(f"{name}_source")
        if src is None:
            continue
        origin = f"EIPs@{src['ref'][:10]} {src['path']}"
        text = eip_text(src)
        address = contracts.get(f"{name}_address")
        if address and address.lower() not in text.lower():
            failures.append(f"{name}: address {address} not in {origin}")
            continue

        theirs = upstream(src, text)
        ours = (
            contracts[name]["code"].lower()
            if isinstance(theirs, str)
            else contracts[name]
        )
        if ours == theirs:
            print(f"OK       {name}")
        elif not args.update:
            failures.append(f"{name}: differs from {origin}")
        else:
            content = rewrite(content, name, theirs)
            print(f"UPDATED  {name} from {origin}")

    if args.update:
        with open(SYSTEM_CONTRACTS, "w") as f:
            f.write(content)
    for failure in failures:
        print(f"FAILED   {failure}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
