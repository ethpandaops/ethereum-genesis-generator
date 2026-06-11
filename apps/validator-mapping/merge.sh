#!/usr/bin/env bash
#
# merge.sh - translate a genesis validator name mapping into the final on-chain
# validator ranges, attributing each range to the client/host that owns the
# underlying keys.
#
# The genesis generator emits a validator mapping (metadata/validator_names.yaml)
# that records, for every contiguous block of on-chain validators, the source
# the keys come from and the key-index range within that source:
#
#   - 0-2799: { src: "main-mnemonic", from: 0, to: 2799 }
#   - 2800-2859: { src: "test-keys", from: 2800, to: 2859 }
#   - 2860-4459: { src: "main-mnemonic", from: 2800, to: 4399 }
#
# Callers know which client/host owns which *key* index range of the main
# mnemonic (the "segments"). This script intersects the two so every on-chain
# range is attributed to the right name, splitting where segment boundaries do
# not line up with the mapping blocks and shifting the result into the on-chain
# index space. Sources other than the main mnemonic are passed through under
# their own name. Without a mapping file the segments are emitted directly
# (key index == on-chain index).
#
# Usage:
#   merge.sh --segments <file|-> [--mapping <file>] [--main-source <name>]
#            [--format yaml|json]
#
#   --segments     JSON array of {"name","start","end"} where start/end are the
#                  inclusive main-mnemonic key index range owned by that name.
#                  Reads from stdin when omitted or set to "-".
#   --mapping      validator_names.yaml. When absent or empty the segments are
#                  emitted directly (1:1 fallback).
#   --main-source  mapping "src" value resolved against the segments
#                  (default: main-mnemonic).
#   --format       yaml (default) -> "<start>-<end>: <name>" lines
#                  json           -> {"ranges": {"<start>-<end>": "<name>"}}
#
set -euo pipefail

mapping_file=""
segments_file="-"
main_source="main-mnemonic"
format="yaml"

while [ $# -gt 0 ]; do
  case "$1" in
    --mapping) mapping_file="$2"; shift 2 ;;
    --segments) segments_file="$2"; shift 2 ;;
    --main-source) main_source="$2"; shift 2 ;;
    --format) format="$2"; shift 2 ;;
    -h | --help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "merge.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$segments_file" = "-" ]; then
  segments_json="$(cat)"
else
  segments_json="$(cat "$segments_file")"
fi

# Convert the mapping YAML to JSON, or fall back to an empty list when there is
# no mapping file. yq (python-yq) transcodes YAML to JSON; "-c" keeps it compact.
if [ -n "$mapping_file" ] && [ -s "$mapping_file" ]; then
  mapping_json="$(yq -c '.' "$mapping_file")"
else
  mapping_json="[]"
fi

jq -rn \
  --argjson mapping "$mapping_json" \
  --argjson segments "$segments_json" \
  --arg main "$main_source" \
  --arg format "$format" '
  # "<start>-<end>" -> {s,e}
  def parse_range($k): ($k | tostring | split("-") | {s: (.[0] | tonumber), e: (.[1] | tonumber)});

  ( if ($mapping | length) == 0 then
      # No mapping: key index == on-chain index, emit segments directly.
      [ $segments[] | {start: .start, range: "\(.start)-\(.end)", name: .name} ]
    else
      [ $mapping[]
        | to_entries[] as $entry
        | parse_range($entry.key) as $oc
        | $entry.value as $v
        | if $v.src != $main then
            # Pass non-main sources through under their own name.
            {start: $oc.s, range: "\($oc.s)-\($oc.e)", name: $v.src}
          else
            # Intersect the mapping block (key range from..to) with every
            # segment and shift the overlap into the on-chain index space.
            ( $segments[]
              | ([$v.from, .start] | max) as $ov_start
              | ([$v.to, .end] | min) as $ov_end
              | select($ov_start <= $ov_end)
              | ($oc.s + $ov_start - $v.from) as $r_start
              | ($oc.s + $ov_end - $v.from) as $r_end
              | {start: $r_start, range: "\($r_start)-\($r_end)", name: .name}
            )
          end
      ]
    end )
  | sort_by(.start)
  | if $format == "json" then
      {ranges: (map({(.range): .name}) | add // {})}
    else
      .[] | "\(.range): \(.name)"
    end
  '
