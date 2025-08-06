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
    local VERBOSE="${VERBOSE:-1}"
    local GAS_PER_BLOB=$((2**17))
    local BLOBS_UP=$((max_blobs - target_blobs))
    local BLOBS_DOWN=$target_blobs

    # Target fee changes
    local TARGET_FEE_DIFF=0.125   # +-12.5%
    local MIN_FEE_DIFF=0.05       # +-5.0%
    
    # Fee multiplier bounds
    local FEE_UP_TARGET=$(echo "1 + $TARGET_FEE_DIFF" | bc -l)      # 1.125
    local FEE_DOWN_TARGET=$(echo "1 - $TARGET_FEE_DIFF" | bc -l)    # 0.875
    local FEE_UP_MIN=$(echo "1 + $MIN_FEE_DIFF" | bc -l)           # 1.05
    local FEE_DOWN_MAX=$(echo "1 - $MIN_FEE_DIFF" | bc -l)         # 0.95

    # Natural logarithms of fee multipliers
    local LN_TARGET_FEE_UP=$(echo "l($FEE_UP_TARGET)" | bc -l)
    local LN_TARGET_FEE_DOWN=$(echo "l($FEE_DOWN_TARGET)" | bc -l | sed 's/^-//')
    local LN_MIN_FEE_UP=$(echo "l($FEE_UP_MIN)" | bc -l)
    local LN_MIN_FEE_DOWN=$(echo "l($FEE_DOWN_MAX)" | bc -l | sed 's/^-//')
    
    # Direct calculation of candidate fractions
    # For up: e^((BLOBS_UP * GAS_PER_BLOB) / F) = FEE_UP_TARGET
    # => (BLOBS_UP * GAS_PER_BLOB) / F = ln(FEE_UP_TARGET)
    # => F = (BLOBS_UP * GAS_PER_BLOB) / ln(FEE_UP_TARGET)
    local fraction_for_up_target=$(echo "($BLOBS_UP * $GAS_PER_BLOB) / $LN_TARGET_FEE_UP" | bc -l)
    
    # For down: e^(-(BLOBS_DOWN * GAS_PER_BLOB) / F) = FEE_DOWN_TARGET
    # => -(BLOBS_DOWN * GAS_PER_BLOB) / F = ln(FEE_DOWN_TARGET)
    # => F = -(BLOBS_DOWN * GAS_PER_BLOB) / ln(FEE_DOWN_TARGET)
    # => F = (BLOBS_DOWN * GAS_PER_BLOB) / -ln(FEE_DOWN_TARGET)
    # => F = (BLOBS_DOWN * GAS_PER_BLOB) / ln(1/FEE_DOWN_TARGET)
    local fraction_for_down_target=$(echo "($BLOBS_DOWN * $GAS_PER_BLOB) / $LN_TARGET_FEE_DOWN" | bc -l)
    
    # Calculate fractions for minimum 5% change
    # For up: e^((BLOBS_UP * GAS_PER_BLOB) / F) = FEE_UP_MIN (1.05)
    local fraction_for_up_min=$(echo "($BLOBS_UP * $GAS_PER_BLOB) / $LN_MIN_FEE_UP" | bc -l)
    
    # For down: e^(-(BLOBS_DOWN * GAS_PER_BLOB) / F) = FEE_DOWN_MAX (0.95)
    local fraction_for_down_min=$(echo "($BLOBS_DOWN * $GAS_PER_BLOB) / $LN_MIN_FEE_DOWN" | bc -l)
    
    # Debug: print the calculated fractions
    [ $VERBOSE == "1" ] && >&2 echo "Candidate fractions:"
    [ $VERBOSE == "1" ] && >&2 printf "  fraction_for_up_target = %.0f (ensures exactly +12.5%%)\n" "$fraction_for_up_target"
    [ $VERBOSE == "1" ] && >&2 printf "  fraction_for_down_target = %.0f (ensures exactly -12.5%%)\n" "$fraction_for_down_target"
    [ $VERBOSE == "1" ] && >&2 printf "  fraction_for_up_min = %.0f (ensures exactly +5.0%%)\n" "$fraction_for_up_min"
    [ $VERBOSE == "1" ] && >&2 printf "  fraction_for_down_min = %.0f (ensures exactly -5.0%%)\n" "$fraction_for_down_min"
    
    # Build list of candidates to test
    local candidates="$fraction_for_down_min $fraction_for_up_target $fraction_for_down_target $fraction_for_up_min"
    
    # Test all candidates and pick the best one
    local best_fraction=0
    local best_distance_to_target=999999
    
    [ $VERBOSE == "1" ] && >&2 echo -e "\nEvaluating candidates:"
    
    for fraction in $candidates; do
        # Calculate actual fee changes
        local fee_up=$(echo "e(($BLOBS_UP * $GAS_PER_BLOB) / $fraction)" | bc -l)
        local fee_down=$(echo "e(-($BLOBS_DOWN * $GAS_PER_BLOB) / $fraction)" | bc -l)
        
        # Calculate percentages
        local fee_up_pct=$(echo "100 * ($fee_up - 1)" | bc -l)
        local fee_down_pct=$(echo "100 * (1 - $fee_down)" | bc -l)
        
        # Check if this candidate passes the hard 5% minimum constraints
        # Use small tolerance for floating point comparisons (0.0001%)
        local tolerance=0.000001
        local passes_constraints=1
        if (( $(echo "$fee_up < ($FEE_UP_MIN - $tolerance)" | bc -l) )); then
            passes_constraints=0
            [ $VERBOSE == "1" ] && >&2 printf "  Fraction %.0f: FAILS - up +%.2f%% < 5%% minimum\n" "$fraction" "$fee_up_pct"
        elif (( $(echo "$fee_down > ($FEE_DOWN_MAX + $tolerance)" | bc -l) )); then
            passes_constraints=0
            [ $VERBOSE == "1" ] && >&2 printf "  Fraction %.0f: FAILS - down -%.2f%% < 5%% minimum\n" "$fraction" "$fee_down_pct"
        elif (( $(echo "$fee_up > ($FEE_UP_TARGET + $tolerance)" | bc -l) )); then
            passes_constraints=0
            [ $VERBOSE == "1" ] && >&2 printf "  Fraction %.0f: FAILS - up +%.2f%% > 12.5%% maximum\n" "$fraction" "$fee_up_pct"
        else
            # Passes all constraints
            # Calculate distance to 12.5% target (minimum of the two distances)
            local dist_up=$(echo "if($fee_up_pct > 12.5) ($fee_up_pct - 12.5) else (12.5 - $fee_up_pct)" | bc -l)
            local dist_down=$(echo "if($fee_down_pct > 12.5) ($fee_down_pct - 12.5) else (12.5 - $fee_down_pct)" | bc -l)
            local min_distance=$(echo "if($dist_up < $dist_down) $dist_up else $dist_down" | bc -l)
            
            [ $VERBOSE == "1" ] && >&2 printf "  Fraction %.0f: PASSES - up +%.2f%%, down -%.2f%% (distance to 12.5%%: %.2f%%)\n" \
                "$fraction" "$fee_up_pct" "$fee_down_pct" "$min_distance"
            
            # Check if this is better (closer to 12.5% on either metric)
            if (( $(echo "$min_distance < $best_distance_to_target" | bc -l) )); then
                best_distance_to_target=$min_distance
                best_fraction=$fraction
                [ $VERBOSE == "1" ] && >&2 echo "    -> New best candidate!"
            fi
        fi
    done
    
    # Check if we found a valid fraction from the standard candidates
    if (( $(echo "$best_fraction == 0" | bc -l) )); then
        [ $VERBOSE == "1" ] && >&2 echo -e "\nNo standard candidate satisfies all constraints."
        [ $VERBOSE == "1" ] && >&2 echo "Relaxing to candidates that meet the 5% minimum constraint..."
        
        # Now consider only candidates that meet the 5% minimum constraint
        # We'll evaluate all 4 candidates but with relaxed criteria
        best_fraction=0
        best_score=999999
        
        [ $VERBOSE == "1" ] && >&2 echo -e "\nRe-evaluating with relaxed criteria (5% minimum must be met):"
        
        for fraction in $fraction_for_up_target $fraction_for_down_target $fraction_for_up_min $fraction_for_down_min; do
            # Calculate actual fee changes
            local fee_up=$(echo "e(($BLOBS_UP * $GAS_PER_BLOB) / $fraction)" | bc -l)
            local fee_down=$(echo "e(-($BLOBS_DOWN * $GAS_PER_BLOB) / $fraction)" | bc -l)
            
            # Calculate percentages
            local fee_up_pct=$(echo "100 * ($fee_up - 1)" | bc -l)
            local fee_down_pct=$(echo "100 * (1 - $fee_down)" | bc -l)
            
            # Check if this candidate meets the 5% minimum constraint
            if (( $(echo "$fee_up_pct >= 5.0 - $tolerance && $fee_down_pct >= 5.0 - $tolerance" | bc -l) )); then
                # Calculate score based on distance to 12.5% target
                # Exceeding 12.5% is twice as bad as being below it
                local score=0
                
                # Score for up percentage
                if (( $(echo "$fee_up_pct > 12.5" | bc -l) )); then
                    # Exceeding is twice as bad
                    local excess=$(echo "$fee_up_pct - 12.5" | bc -l)
                    score=$(echo "$score + ($excess * 2)" | bc -l)
                else
                    # Being below is normal penalty
                    local deficit=$(echo "12.5 - $fee_up_pct" | bc -l)
                    score=$(echo "$score + $deficit" | bc -l)
                fi
                
                # Score for down percentage
                if (( $(echo "$fee_down_pct > 12.5" | bc -l) )); then
                    # Exceeding is twice as bad
                    local excess=$(echo "$fee_down_pct - 12.5" | bc -l)
                    score=$(echo "$score + ($excess * 2)" | bc -l)
                else
                    # Being below is normal penalty
                    local deficit=$(echo "12.5 - $fee_down_pct" | bc -l)
                    score=$(echo "$score + $deficit" | bc -l)
                fi
                
                [ $VERBOSE == "1" ] && >&2 printf "  Fraction %.0f: VALID - up +%.2f%%, down -%.2f%%, score %.2f" \
                    "$fraction" "$fee_up_pct" "$fee_down_pct" "$score"
                
                if (( $(echo "$score < $best_score" | bc -l) )); then
                    best_score=$score
                    best_fraction=$fraction
                    [ $VERBOSE == "1" ] && >&2 echo " <- best so far"
                else
                    [ $VERBOSE == "1" ] && >&2 echo ""
                fi
            else
                [ $VERBOSE == "1" ] && >&2 printf "  Fraction %.0f: INVALID - up +%.2f%%, down -%.2f%% (violates 5%% minimum)\n" \
                    "$fraction" "$fee_up_pct" "$fee_down_pct"
            fi
        done
        
        if (( $(echo "$best_fraction == 0" | bc -l) )); then
            [ $VERBOSE == "1" ] && >&2 echo -e "\nERROR: No candidate meets the 5% minimum constraint!"
            [ $VERBOSE == "1" ] && >&2 echo "This configuration is impossible to satisfy."
            # Return a reasonable default that at least doesn't cause division by zero
            best_fraction=$fraction_for_up_min
        fi
    fi
    
    # Round to nearest integer for cleaner output
    [ $VERBOSE == "1" ] && >&2 echo ""
    echo "($best_fraction + 0.5)/1" | bc
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