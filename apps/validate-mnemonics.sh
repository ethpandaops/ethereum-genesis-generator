#!/bin/bash

# validate-mnemonics.sh
# Validates that mnemonics.yaml has no overlapping validator ranges per mnemonic

set -e

validate_mnemonics() {
    local mnemonics_file="$1"
    
    if [ ! -f "$mnemonics_file" ]; then
        echo "Error: Mnemonics file '$mnemonics_file' not found" >&2
        return 1
    fi

    # Use yq to parse YAML if available, otherwise fall back to basic parsing
    if command -v yq >/dev/null 2>&1; then
        validate_with_yq "$mnemonics_file"
    else
        validate_with_awk "$mnemonics_file"
    fi
}

validate_with_yq() {
    local mnemonics_file="$1"
    local temp_file=$(mktemp)
    local error_file=$(mktemp)
    
    # Extract all mnemonics and their ranges
    yq eval '.[] | [.mnemonic, .start, .count] | @csv' "$mnemonics_file" > "$temp_file"
    
    # Group by mnemonic and validate each group
    local current_mnemonic=""
    local ranges_file=$(mktemp)
    
    {
        sort "$temp_file"
        echo "END_OF_FILE"  # Sentinel to process last group
    } | while IFS=, read -r mnemonic start count; do
        if [ "$mnemonic" != "$current_mnemonic" ] || [ "$mnemonic" = "END_OF_FILE" ]; then
            if [ -n "$current_mnemonic" ] && [ -s "$ranges_file" ]; then
                if ! check_overlaps "$current_mnemonic" "$(cat "$ranges_file")"; then
                    echo "ERROR" >> "$error_file"
                fi
            fi
            current_mnemonic="$mnemonic"
            > "$ranges_file"  # Clear ranges file
        fi
        if [ "$mnemonic" != "END_OF_FILE" ]; then
            echo "$start:$count" >> "$ranges_file"
        fi
    done
    
    # Check if there were any errors
    local error_count=0
    if [ -f "$error_file" ]; then
        error_count=$(wc -l < "$error_file" 2>/dev/null || echo 0)
    fi
    
    # Cleanup
    rm -f "$temp_file" "$ranges_file" "$error_file"
    
    return $error_count
}

validate_with_awk() {
    local mnemonics_file="$1"
    local temp_file=$(mktemp)
    
    # Parse YAML manually using awk
    awk '
        /^[[:space:]]*-[[:space:]]+mnemonic:/ {
            gsub(/^[[:space:]]*-[[:space:]]+mnemonic:[[:space:]]*/, "")
            gsub(/["]/, "")
            current_mnemonic = $0
        }
        /^[[:space:]]+start:/ {
            gsub(/^[[:space:]]+start:[[:space:]]*/, "")
            start = $0
        }
        /^[[:space:]]+count:/ {
            gsub(/^[[:space:]]+count:[[:space:]]*/, "")
            count = $0
            if (current_mnemonic && start != "" && count != "") {
                print current_mnemonic "," start "," count
            }
        }
    ' "$mnemonics_file" > "$temp_file"
    
    # Check for overlaps per mnemonic
    local current_mnemonic=""
    local -a ranges=()
    
    sort "$temp_file" | while IFS=, read -r mnemonic start count; do
        if [ "$mnemonic" != "$current_mnemonic" ]; then
            if [ -n "$current_mnemonic" ]; then
                check_overlaps "$current_mnemonic" "${ranges[@]}"
            fi
            current_mnemonic="$mnemonic"
            ranges=()
        fi
        ranges+=("$start:$count")
    done
    
    # Check last group
    if [ -n "$current_mnemonic" ]; then
        check_overlaps "$current_mnemonic" "${ranges[@]}"
    fi
    
    rm -f "$temp_file"
}

check_overlaps() {
    local mnemonic="$1"
    local ranges_data="$2"
    local validation_errors=0
    
    echo "Validating mnemonic: $mnemonic"
    
    # Convert ranges data to array and sort by start index
    local -a ranges=()
    while IFS= read -r line; do
        [ -n "$line" ] && ranges+=("$line")
    done <<< "$ranges_data"
    
    # Simple bubble sort by start index
    local n=${#ranges[@]}
    for ((i = 0; i < n-1; i++)); do
        for ((j = 0; j < n-i-1; j++)); do
            local start1=$(echo "${ranges[j]}" | cut -d: -f1)
            local start2=$(echo "${ranges[j+1]}" | cut -d: -f1)
            if [ "$start1" -gt "$start2" ]; then
                local temp="${ranges[j]}"
                ranges[j]="${ranges[j+1]}"
                ranges[j+1]="$temp"
            fi
        done
    done
    
    # Check for overlaps in sorted ranges
    local prev_end=-1
    for range in "${ranges[@]}"; do
        local start=$(echo "$range" | cut -d: -f1)
        local count=$(echo "$range" | cut -d: -f2)
        local end=$((start + count - 1))
        
        echo "  Range: start=$start, count=$count, end=$end"
        
        if [ "$start" -le "$prev_end" ]; then
            echo "ERROR: Overlapping validator ranges detected for mnemonic '$mnemonic'!" >&2
            echo "  Previous range ended at index $prev_end, but current range starts at $start" >&2
            validation_errors=$((validation_errors + 1))
        fi
        
        prev_end=$end
    done
    
    if [ "$validation_errors" -gt 0 ]; then
        echo "Validation failed for mnemonic '$mnemonic' with $validation_errors errors" >&2
        return 1
    else
        echo "✓ No overlaps found for mnemonic '$mnemonic'"
        return 0
    fi
}

# Main execution
main() {
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <mnemonics.yaml>"
        echo "Example: $0 /config/cl/mnemonics.yaml"
        exit 1
    fi
    
    local mnemonics_file="$1"
    echo "Validating mnemonics file: $mnemonics_file"
    
    if validate_mnemonics "$mnemonics_file"; then
        echo "✓ All mnemonic validator ranges are valid - no overlaps detected"
        exit 0
    else
        echo "✗ Validation failed - overlapping validator ranges detected"
        exit 1
    fi
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi