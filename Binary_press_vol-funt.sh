#!/bin/bash
#===============================================================================
# VASP Binary Search for Target Pressure via Volume Optimization
# 
# USAGE: vasp_pressure_search <temperature> <expected_volume> <target_pressure>
# 
# EXAMPLE: vasp_pressure_search 3000 3500 50
#          (Search for 50 kB pressure at 3000K around 3500 Ang³ volume)
#
# REQUIREMENTS:
# - POSCAR file in current directory
# - VASP executable (vasp_std) in PATH
# - POTCAR files in $HOME/POTs/ELEMENT/ directory
# - Running in SLURM environment with srun
#===============================================================================

# Configuration constants
readonly ELEMENT="Mg"
readonly ATOMS=128
readonly KPOINTS_MESH="1 1 1"
readonly MDSTEPS=200
readonly NBLOCKS=20
readonly PRESSURE_TOLERANCE=5
readonly MAX_ITERATIONS=15
readonly VOLUME_RANGE=300  # ±300 Ang³ around expected volume

# Global result variables
FOUND_VOLUME=0
SEARCH_SUCCESS=0
CSV_FILENAME=""

#===============================================================================
# DOCUMENTATION: Function Overview
#===============================================================================
# write_incar()         - Creates INCAR file with MD simulation parameters
# create_kpoints()      - Generates KPOINTS file for k-point sampling
# setup_potcar()        - Copies POTCAR file from standard location
# set_volume()          - Modifies POSCAR to set specific volume
# calculate_averages()  - Extracts average pressure/temperature from output
# run_simulation_step() - Executes complete VASP calculation for one volume
# evaluate_volume()     - Runs simulation and returns pressure for given volume
# binary_search_volume() - Main search algorithm to find target pressure
# init_csv_log()        - Creates CSV file to log volume-pressure data
# log_to_csv()          - Appends volume-pressure pair to CSV file
# vasp_pressure_search() - Main callable function (entry point)
#===============================================================================

#===============================================================================
# Input file generation functions
#===============================================================================

# Creates INCAR file with molecular dynamics parameters
write_incar() {
    local temp=$1
    local temp_elec=$(awk "BEGIN {printf \"%.6f\", $temp * 8.617e-5}")
    
    cat > INCAR << EOF
    SYSTEM = $ELEMENT, $ATOMS atoms
    MAXMIX = 60; NPAR = 4; LCHARG = .FALSE.; LWAVE = .FALSE.; NWRITE = 0
    IALGO = 48; ISYM = 0; IBRION = 0; NBLOCK = $NBLOCKS; KBLOCK = 1
    SMASS = 1.0; POTIM = 2.0; ISIF = 1
    TEBEG = $temp; NSW = $MDSTEPS
EOF
}

# Creates KPOINTS file for Brillouin zone sampling
create_kpoints() {
    cat > KPOINTS << EOF
    K-Points
    0
    Monkhorst Pack
    $KPOINTS_MESH
    0 0 0
EOF
}

# Copies POTCAR file from standard location
setup_potcar() {
    local potcar_path="$HOME/POTs/$ELEMENT/POTCAR"
    
    if [[ -f "POTCAR" ]]; then
        echo "POTCAR already exists" >&2
        return 0
    fi
    
    if [[ ! -f "$potcar_path" ]]; then
        echo "ERROR: POTCAR not found at $potcar_path" >&2
        return 1
    fi
    
    # Try different copy methods (no sudo needed)
    cp "$potcar_path" . 2>/dev/null || \
    cat "$potcar_path" > POTCAR 2>/dev/null || {
        echo "ERROR: Cannot copy POTCAR - check file permissions" >&2
        return 1
    }
    
    echo "POTCAR copied successfully" >&2
    return 0
}

#===============================================================================
# Structure manipulation functions
#===============================================================================

# Modifies POSCAR file to set specific volume
set_volume() {
    local target_vol=$1
    
    if [[ ! -f POSCAR ]]; then
        echo "ERROR: POSCAR not found" >&2
        return 1
    fi
    
    # Create backup of original POSCAR on first run
    [[ ! -f POSCAR.original ]] && cp POSCAR POSCAR.original
    
    # Set volume using sed (line 2 contains volume scaling factor)
    sed "2s/.*/   -$target_vol/" POSCAR.original > POSCAR
    
    echo "Volume set to $target_vol Ang³" >&2
    return 0
}

#===============================================================================
# Output analysis functions
#===============================================================================

# Extracts average pressure and temperature from VASP output files
calculate_averages() {
    local outcar_file="${1:-OUTCAR}"
    local oszicar_file="${2:-OSZICAR}"
    local log_file="${3:-results.log}"
    
    # Wait for output files to be generated
    local wait_count=0
    while [[ (! -f "$outcar_file" || ! -f "$oszicar_file") && $wait_count -lt 30 ]]; do
        echo "Waiting for output files... ($wait_count/30)" >&2
        sleep 2
        wait_count=$((wait_count + 1))
    done
    
    if [[ ! -f "$outcar_file" || ! -f "$oszicar_file" ]]; then
        echo "ERROR: Output files not found after waiting" >&2
        return 1
    fi
    
    # Extract average pressure from OUTCAR
    local pressure_result=$(awk '
        /external pressure/ {sum+=$4; count++} 
        /total.*pressure/ {if($4 != "") {sum+=$4; count++}}
        END {
            if(count>0) printf "%.2f", sum/count; 
            else printf "N/A"
        }' "$outcar_file")
    
    # Extract average temperature from OSZICAR
    local temp_result=$(awk '
        /T=/ {
            gsub(/T=/, "", $0);
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9]+\.?[0-9]*$/) {
                    sum+=$i; count++; break
                }
            }
        }
        END {
            if(count>0) printf "%.2f", sum/count; 
            else printf "N/A"
        }' "$oszicar_file")
    
    # Log results
    if [[ -n "$pressure_result" && "$pressure_result" != "N/A" ]]; then
        echo "Pressure: ${pressure_result} kB, Temperature: ${temp_result} K" >&2
        echo "Pressure: ${pressure_result} kB, Temperature: ${temp_result} K" >> "$log_file"
    else
        echo "Warning: No pressure data found in output files" >&2
    fi
    
    echo "$pressure_result $temp_result"
}


#===============================================================================
# CSV logging functions
#===============================================================================


init_csv_log() {
    local temperature=$1
    local target_pressure=$2
    
    # Create filename: VP_Temperature_TargetPressure.csv
    CSV_FILENAME="VP_${temperature}_${target_pressure}.csv"
    
    # Write CSV header
    echo "Volume,Pressure" > "$CSV_FILENAME"
    
    echo "Created CSV log file: $CSV_FILENAME" >&2
}

# Appends volume-pressure pair to the CSV file
log_to_csv() {
    local volume=$1
    local pressure=$2
    
    if [[ -n "$CSV_FILENAME" && -n "$volume" && -n "$pressure" && "$pressure" != "N/A" ]]; then
        echo "$volume,$pressure" >> "$CSV_FILENAME"
        echo "Logged to CSV: Volume=$volume, Pressure=$pressure" >&2
    fi
}


#===============================================================================
# Simulation execution functions
#===============================================================================

# Executes complete VASP calculation for one volume point
run_simulation_step() {
    local volume=$1
    local temperature=$2
    
    echo "Setting up simulation for volume $volume Ang³..." >&2
    
    # Prepare input files
    set_volume "$volume" || return 1
    write_incar "$temperature"
    create_kpoints
    setup_potcar || return 1
    
    # Clean previous output files
    rm -f OUTCAR OSZICAR 2>/dev/null
    
    # Run VASP calculation
    echo "Running VASP calculation ($MDSTEPS steps at $temperature K)" >&2
    srun vasp_std > "vasp_output_${volume}.log" 2>&1
    local vasp_exit=$?
    
    if [[ $vasp_exit -ne 0 ]]; then
        echo "ERROR: VASP exited with code $vasp_exit" >&2
        return 1
    fi
    
    # Verify output files were created
    if [[ ! -f OUTCAR || ! -f OSZICAR ]]; then
        echo "ERROR: Output files not generated for volume $volume Ang³" >&2
        return 1
    fi
    
    return 0
}

# Runs simulation and returns pressure for given volume
evaluate_volume() {
    local volume=$1
    local temperature=$2
    
    echo "=== Evaluating volume: $volume Ang³ ===" >&2
    
    # Reset to original structure
    if [[ -f POSCAR.original ]]; then
        cp POSCAR.original POSCAR
    else
        echo "ERROR: Original POSCAR not found!" >&2
        return 1
    fi
    
    # Run simulation
    run_simulation_step "$volume" "$temperature" || return 1
    
    # Calculate averages
    local results=$(calculate_averages "OUTCAR" "OSZICAR" "results_${volume}A3.log")
    
    if [[ -z "$results" ]]; then
        echo "ERROR: No results available" >&2
        return 1
    fi
    
    # Parse results
    local pressure=$(echo $results | awk '{print $1}')
    local temp_avg=$(echo $results | awk '{print $2}')
    
    if [[ "$pressure" == "N/A" || -z "$pressure" ]]; then
        echo "ERROR: No pressure data available" >&2
        return 1
    fi
    
    echo "Result: Pressure = $pressure kB, Temperature = $temp_avg K" >&2
    echo "==================================" >&2
    
    # Save results with volume labels
    cp OUTCAR "OUTCAR_${volume}A3" 2>/dev/null
    cp OSZICAR "OSZICAR_${volume}A3" 2>/dev/null
    cp INCAR "INCAR_${volume}A3" 2>/dev/null
    
    # Log volume-pressure data to CSV file
    log_to_csv "$volume" "$pressure"
    
    # Return pressure value for binary search
    echo "$pressure"
}

#===============================================================================
# Main search algorithm
#===============================================================================

# Binary search algorithm to find volume that gives target pressure
binary_search_volume() {
    local target_pressure=$1
    local temperature=$2
    local vol_min=$3
    local vol_max=$4
    
    local low=$vol_min
    local high=$vol_max
    local iteration=1
    
    echo "Starting binary search:"
    echo "  Range: $low - $high Ang³"
    echo "  Target pressure: $target_pressure kB"
    echo "  Tolerance: $PRESSURE_TOLERANCE kB"
    echo "================================================="
    
    while [[ $iteration -le $MAX_ITERATIONS ]]; do
        local mid=$(awk "BEGIN {printf \"%.0f\", ($low + $high) / 2}")
        
        echo "Iteration $iteration: Testing volume $mid Ang³"
        
        # Get pressure at this volume
        local pressure=$(evaluate_volume "$mid" "$temperature")
        
        if [[ -z "$pressure" ]]; then
            echo "ERROR: Failed to evaluate volume $mid Ang³"
            return 1
        fi
        
        # Check if target pressure is reached
        local abs_diff=$(awk "BEGIN {printf \"%.2f\", sqrt(($pressure - $target_pressure)^2)}")
        echo "Pressure difference from target: $abs_diff kB"
        
        if (( $(awk "BEGIN {print ($abs_diff <= $PRESSURE_TOLERANCE)}") )); then
            echo "SUCCESS: Found target pressure!"
            FOUND_VOLUME=$mid
            SEARCH_SUCCESS=1
            return 0
        fi
        
        # Binary search logic: pressure decreases with increasing volume
        if (( $(awk "BEGIN {print ($pressure > $target_pressure)}") )); then
            echo "Pressure too high -> trying larger volume"
            low=$mid
        else
            echo "Pressure too low -> trying smaller volume"
            high=$mid
        fi
        
        # Check for convergence
        local range=$(awk "BEGIN {printf \"%.2f\", ($high - $low)}")
        echo "Current search range: $range Ang³"
        
        if (( $(awk "BEGIN {print ($range <= 5.0)}") )); then
            echo "Range converged to within 5.0 Ang³"
            FOUND_VOLUME=$(awk "BEGIN {printf \"%.0f\", ($low + $high) / 2}")
            SEARCH_SUCCESS=1
            return 0
        fi
        
        iteration=$((iteration + 1))
        echo "-------------------------------------------------"
    done
    
    echo "Maximum iterations reached"
    FOUND_VOLUME=$(awk "BEGIN {printf \"%.0f\", ($low + $high) / 2}")
    SEARCH_SUCCESS=0
    return 1
}


#===============================================================================
# Main callable function
#===============================================================================

# Main function: searches for volume that produces target pressure
# Usage: vasp_pressure_search <melting temperature> <expected_volume> <Melting_pressure>
vasp_pressure_search() {
    # Check arguments
    if [[ $# -ne 3 ]]; then
        echo "Usage: vasp_pressure_search <temperature> <expected_volume> <target_pressure>"
        echo "Example: vasp_pressure_search 3000 3500 50"
        echo "  temperature: Temperature in Kelvin"
        echo "  expected_volume: Expected volume in Ang³ (search center)"
        echo "  target_pressure: Target pressure in kB"
        return 1
    fi
    
    local temperature=$1
    local expected_volume=$2
    local target_pressure=$3
    
    # Validate inputs
    if [[ ! "$temperature" =~ ^[0-9]+$ ]] || [[ ! "$expected_volume" =~ ^[0-9]+$ ]] || [[ ! "$target_pressure" =~ ^[0-9.-]+$ ]]; then
        echo "ERROR: All arguments must be numeric"
        return 1
    fi
    
    # Calculate search range
    local vol_min=$((expected_volume - VOLUME_RANGE))
    local vol_max=$((expected_volume + VOLUME_RANGE))
    
    # Check for required files
    if [[ ! -f POSCAR ]]; then
        echo "ERROR: POSCAR file not found in current directory"
        return 1
    fi
    
    # Display search parameters
    echo "VASP Volume Binary Search"
    echo "========================"
    echo "Element: $ELEMENT ($ATOMS atoms)"
    echo "Temperature: $temperature K"
    echo "Expected volume: $expected_volume Ang³"
    echo "Search range: $vol_min - $vol_max Ang³"
    echo "Target pressure: $target_pressure kB"
    echo ""
    
    # Initialize CSV logging file
    init_csv_log "$temperature" "$target_pressure"
    
    # Create backup of original POSCAR
    cp POSCAR POSCAR.original
    
    # Perform binary search
    if binary_search_volume "$target_pressure" "$temperature" "$vol_min" "$vol_max"; then
        echo ""
        echo "==============================================="
        echo "SEARCH COMPLETED SUCCESSFULLY"
        echo "==============================================="
        echo "Target volume: $FOUND_VOLUME Ang³"
        echo "Achieved pressure: $target_pressure kB (±$PRESSURE_TOLERANCE kB)"
    else
        echo ""
        echo "==============================================="
        echo "SEARCH COMPLETED WITH ESTIMATE"
        echo "==============================================="
        echo "Best volume estimate: $FOUND_VOLUME Ang³"
        echo "Target pressure not reached within tolerance"
    fi
    
    echo ""
    echo "Results saved:"
    echo "  $CSV_FILENAME - Volume-pressure data for all tested points"
    echo "  OUTCAR_*A3, OSZICAR_*A3, INCAR_*A3 - Output files for each volume"
    echo "  vasp_output_*.log - VASP execution logs"
    echo "  results_*A3.log - Pressure/temperature analysis"
    
    return $([[ $SEARCH_SUCCESS -eq 1 ]] && echo 0 || echo 1)
}

# If script is run directly (not sourced), execute the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    vasp_pressure_search "$@"
fi