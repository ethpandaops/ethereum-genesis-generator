#!/bin/bash

# Calculate an optimal BASEFEE_UPDATE_FRACTION for blob fee calculations
# This script computes a value that produces fee changes closest to 
# +12.5% when at MAX_BLOBS_PER_BLOCK and -12.5% when at TARGET_BLOBS_PER_BLOCK
# Constraints:
# - Increase should be <= 12.5%
# - Both increase and decrease should be >= 5.0% (absolute value)

calculate_basefee_fraction() {
    local max_blobs=$1
    local target_blobs=$2
    
    # Constants
    local GAS_PER_BLOB=$((2**17))
    local BLOBS_UP=$((max_blobs - target_blobs))
    local BLOBS_DOWN=$target_blobs

    # Target fee changes
    local TARGET_FEE_DIFF=0.125   # +-12.5%
    local MIN_FEE_DIFF=0.05       # +-5.0%

    local LN_TARGET_FEE_UP=$(echo "l(1 + $TARGET_FEE_DIFF)" | bc -l)
    local LN_TARGET_FEE_DOWN=$(echo "l(1 - $TARGET_FEE_DIFF)" | bc -l | sed 's/^-//')
    local LN_MIN_FEE_UP=$(echo "l(1 + $MIN_FEE_DIFF)" | bc -l)
    local LN_MAX_FEE_DOWN=$(echo "l(1 - $MIN_FEE_DIFF)" | bc -l | sed 's/^-//')
    
    # Direct calculation of initial fractions using precomputed values
    local fraction_for_up=$(echo "($BLOBS_UP * $GAS_PER_BLOB) / $LN_TARGET_FEE_UP" | bc -l)
    local fraction_for_down=$(echo "($BLOBS_DOWN * $GAS_PER_BLOB) / $LN_TARGET_FEE_DOWN" | bc -l)
    
    # Establish initial search space with a reasonable range
    local min_fraction=$(echo "if($fraction_for_up < $fraction_for_down) $fraction_for_up else $fraction_for_down" | bc -l)
    local max_fraction=$(echo "if($fraction_for_up > $fraction_for_down) $fraction_for_up else $fraction_for_down" | bc -l)
    local range=$(echo "$max_fraction - $min_fraction" | bc -l)
    
    # Expand initial search space
    min_fraction=$(echo "$min_fraction - ($range * 0.1)" | bc -l)
    max_fraction=$(echo "$max_fraction + ($range * 0.1)" | bc -l)
    
    # Multi-pass search with narrowing ranges
    local best_fraction=0
    local best_error=999999
    
    # Fewer passes with more targeted steps
    local passes=5
    
    for ((pass=1; pass<=passes; pass++)); do
        # Convert to integers for the loop
        local min_int=$(echo "($min_fraction)/1" | bc)
        local max_int=$(echo "($max_fraction+0.5)/1" | bc)
        
        # Calculate step size - larger steps for faster execution
        local steps_per_pass=30
        local step=$((($max_int - $min_int) / $steps_per_pass))
        if [ "$step" -lt 1 ]; then
            step=1
        fi
        
        #echo "Pass $pass: range $min_int-$max_int, step $step" > /dev/stderr
        
        # Local best for this pass
        local pass_best_fraction=0
        local pass_best_error=999999
        
        for ((fraction=min_int; fraction<=max_int; fraction+=step)); do
            # Use bc just once per fraction and store the results
            local fee_up=$(echo "e(($BLOBS_UP * $GAS_PER_BLOB) / $fraction)" | bc -l)
            local fee_down=$(echo "e(-($BLOBS_DOWN * $GAS_PER_BLOB) / $fraction)" | bc -l)
            
            # Calculate error score for this fraction
            # Use efficient in-line error calculations
            local error_up=0
            local error_down=0
            
            # For up error
            if (( $(echo "$fee_up > 1.125" | bc -l) )); then
                # Above upper limit - heavy penalty
                error_up=$(echo "($fee_up - 1.125) * 3.0" | bc -l)
            elif (( $(echo "$fee_up < 1.05" | bc -l) )); then
                # Below lower limit - medium penalty
                error_up=$(echo "(1.05 - $fee_up) * 2.0" | bc -l)
            else
                # Within limits - light penalty
                error_up=$(echo "(1.125 - $fee_up) * 0.5" | bc -l)
            fi
            
            # For down error
            if (( $(echo "$fee_down > 0.95" | bc -l) )); then
                # Not enough decrease
                error_down=$(echo "($fee_down - 0.95) * 2.0" | bc -l)
            else
                # Enough decrease
                error_down=$(echo "if($fee_down > 0.875) ($fee_down - 0.875) else (0.875 - $fee_down)" | bc -l)
            fi
            
            # Total error
            local total_error=$(echo "(1.2 * $error_up) + (0.8 * $error_down)" | bc -l)
            
            # Check if this is better
            if (( $(echo "$total_error < $pass_best_error" | bc -l) )); then
                pass_best_error=$total_error
                pass_best_fraction=$fraction
            fi
            
            if (( $(echo "$total_error < $best_error" | bc -l) )); then
                best_error=$total_error
                best_fraction=$fraction
            fi
        done
        
        # Narrow the search range around the best fraction from this pass
        local narrow_factor=0.2
        range=$(echo "($max_int - $min_int) * $narrow_factor" | bc -l)
        min_fraction=$(echo "$pass_best_fraction - $range" | bc -l)
        max_fraction=$(echo "$pass_best_fraction + $range" | bc -l)
    done
    
    echo "$best_fraction"
}

# Function to display the resulting values and verification
show_results() {
    local max_blobs=$1
    local target_blobs=$2
    local fraction=$3
    
    local GAS_PER_BLOB=$((2**17))
    local BLOBS_UP=$((max_blobs - target_blobs))
    local BLOBS_DOWN=$target_blobs
    
    local blob_fee_up=$(echo "e(($BLOBS_UP * $GAS_PER_BLOB) / $fraction)" | bc -l)
    local blob_fee_down=$(echo "e(-($BLOBS_DOWN * $GAS_PER_BLOB) / $fraction)" | bc -l)
    
    local fee_up_pct=$(echo "100 * ($blob_fee_up - 1)" | bc -l)
    local fee_down_pct=$(echo "100 * (1 - $blob_fee_down)" | bc -l)
    
    echo "Results for MAX_BLOBS=$max_blobs, TARGET_BLOBS=$target_blobs:"
    echo "Optimal BASEFEE_UPDATE_FRACTION = $fraction"
    printf "Blob fee increases by factor of %.6f (+%.2f%%) when at max blobs (target: +12.5%%, min: +5.0%%)\n" "$blob_fee_up" "$fee_up_pct"
    printf "Blob fee decreases by factor of %.6f (-%.2f%%) when at target blobs (target: -12.5%%, min: -5.0%%)\n" "$blob_fee_down" "$fee_down_pct"
    
    echo
}

# Use if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$#" -lt 2 ]; then
        echo "Usage: $0 MAX_BLOBS_PER_BLOCK TARGET_BLOBS_PER_BLOCK [BASEFEE_UPDATE_FRACTION]"
        exit 1
    fi
    
    max_blobs=$1
    target_blobs=$2
    
    if [ -z "$3" ]; then
        fraction=$(calculate_basefee_fraction $max_blobs $target_blobs)
    else
        fraction=$3
    fi
 
    show_results $max_blobs $target_blobs $fraction
fi
