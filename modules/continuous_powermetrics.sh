#!/bin/bash

# ==============================================================================
# Continuous Powermetrics Monitoring Module
# Runs powermetrics once and continuously reads sensor data
# ==============================================================================

# Global variables for continuous monitoring
POWERMETRICS_PID=""
POWERMETRICS_FIFO="/tmp/powermetrics_fifo_$$"
POWERMETRICS_RUNNING=0

# Start continuous powermetrics monitoring
start_continuous_powermetrics() {
    local samplers="$1"
    local interval="${2:-500}"  # Default 500ms interval

    # Clean up any existing FIFO
    cleanup_continuous_powermetrics

    # Create FIFO for inter-process communication
    mkfifo "$POWERMETRICS_FIFO" 2>/dev/null || return 1

    # Start powermetrics in background with continuous output
    powermetrics -i $interval --samplers $samplers > "$POWERMETRICS_FIFO" 2>/dev/null &
    POWERMETRICS_PID=$!
    POWERMETRICS_RUNNING=1

    log "${GREEN}[监控] 连续 powermetrics 监控已启动 (PID: $POWERMETRICS_PID)${NC}"
    return 0
}

# Stop continuous powermetrics monitoring
cleanup_continuous_powermetrics() {
    if [ $POWERMETRICS_RUNNING -eq 1 ]; then
        # Kill powermetrics process
        if kill -0 $POWERMETRICS_PID 2>/dev/null; then
            kill $POWERMETRICS_PID 2>/dev/null
            wait $POWERMETRICS_PID 2>/dev/null
        fi

        # Remove FIFO
        rm -f "$POWERMETRICS_FIFO"

        POWERMETRICS_RUNNING=0
        POWERMETRICS_PID=""
        log "${YELLOW}[监控] 连续 powermetrics 监控已停止${NC}"
    fi
}

# Read next available sensor data from continuous powermetrics
read_powermetrics_sensor_data() {
    local timeout="${1:-2}"  # Default 2 second timeout

    if [ $POWERMETRICS_RUNNING -eq 0 ]; then
        return 1
    fi

    # Use timeout to avoid blocking indefinitely
    if timeout $timeout cat "$POWERMETRICS_FIFO" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Parse sensor data from powermetrics output
parse_powermetrics_sensors() {
    local input="$1"

    # Initialize return values
    local cpu_temp="0"
    local gpu_temp="0"
    local fan_rpm="0"
    local cpu_plimit="0.00"
    local prochots="0"
    local thermal_level="0"

    # Extract CPU die temperature
    local temp_match=$(echo "$input" | awk '/CPU die temperature:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print int($i); break}}')
    if [ -n "$temp_match" ] && [ "$temp_match" -ge 0 ] && [ "$temp_match" -le 120 ]; then
        cpu_temp="$temp_match"
    fi

    # Extract GPU die temperature
    temp_match=$(echo "$input" | awk '/GPU die temperature:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print int($i); break}}')
    if [ -n "$temp_match" ] && [ "$temp_match" -ge 0 ] && [ "$temp_match" -le 120 ]; then
        gpu_temp="$temp_match"
    fi

    # Extract fan RPM
    local fan_match=$(echo "$input" | awk '/Fan:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print int($i); break}}')
    if [ -n "$fan_match" ] && [ "$fan_match" -ge 0 ] && [ "$fan_match" -le 10000 ]; then
        fan_rpm="$fan_match"
    fi

    # Extract CPU Plimit
    local plimit_match=$(echo "$input" | awk '/CPU Plimit:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print $i; break}}')
    if [ -n "$plimit_match" ]; then
        cpu_plimit="$plimit_match"
    fi

    # Extract prochots
    local prochots_match=$(echo "$input" | awk '/Number of prochots:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
    if [ -n "$prochots_match" ]; then
        prochots="$prochots_match"
    fi

    # Extract thermal level
    local thermal_match=$(echo "$input" | awk '/CPU Thermal level:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) {print $i; break}}')
    if [ -n "$thermal_match" ]; then
        thermal_level="$thermal_match"
    fi

    # Output as space-separated values
    echo "$cpu_temp $gpu_temp $fan_rpm $cpu_plimit $prochots $thermal_level"
}

# Parse power data from powermetrics output
parse_powermetrics_power() {
    local input="$1"

    local cpu_power="N/A"
    local gpu_power="N/A"
    local mem_power="N/A"

    # Extract CPU power
    local power_match=$(echo "$input" | awk '
    /CPU Power:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+W$/) {gsub(/W/, "", $i); print $i; exit}}
    /Package Power:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+W$/) {gsub(/W/, "", $i); print $i; exit}}
    /CPU package power:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+W$/) {gsub(/W/, "", $i); print $i; exit}}
    ' | head -1)

    if [ -n "$power_match" ]; then
        cpu_power="$power_match"
    fi

    # Extract GPU power
    power_match=$(echo "$input" | awk '
    /GPU Power:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+W$/) {gsub(/W/, "", $i); print $i; exit}}
    /GPU package power:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+W$/) {gsub(/W/, "", $i); print $i; exit}}
    ' | head -1)

    if [ -n "$power_match" ]; then
        gpu_power="$power_match"
    fi

    # Extract memory power
    power_match=$(echo "$input" | awk '
    /Memory Power:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+W$/) {gsub(/W/, "", $i); print $i; exit}}
    /DRAM Power:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+W$/) {gsub(/W/, "", $i); print $i; exit}}
    ' | head -1)

    if [ -n "$power_match" ]; then
        mem_power="$power_match"
    fi

    echo "$cpu_power $gpu_power $mem_power"
}

# Continuous monitoring wrapper functions
get_continuous_sensor_data() {
    local cpu_temp_var="$1"
    local gpu_temp_var="$2"
    local fan_rpm_var="$3"
    local c_plimit_var="$4"
    local c_prochot_var="$5"
    local c_thermlvl_var="$6"

    # Initialize return values
    eval "$cpu_temp_var='0'"
    eval "$gpu_temp_var='0'"
    eval "$fan_rpm_var='0'"
    eval "$c_plimit_var='0.00'"
    eval "$c_prochot_var='0'"
    eval "$c_thermlvl_var='0'"

    # Read from continuous powermetrics
    local pm_output
    pm_output=$(read_powermetrics_sensor_data 2)
    if [ $? -eq 0 ] && [ -n "$pm_output" ]; then
        # Parse sensor data
        local parsed_data
        parsed_data=$(parse_powermetrics_sensors "$pm_output")
        if [ -n "$parsed_data" ]; then
            set -- $parsed_data
            eval "$cpu_temp_var='$1'"
            eval "$gpu_temp_var='$2'"
            eval "$fan_rpm_var='$3'"
            eval "$c_plimit_var='$4'"
            eval "$c_prochot_var='$5'"
            eval "$c_thermlvl_var='$6'"
            return 0
        fi
    fi

    return 1
}

get_continuous_power_data() {
    local cpu_power_var="$1"
    local gpu_power_var="$2"
    local mem_power_var="$3"

    # Initialize return values
    eval "$cpu_power_var='N/A'"
    eval "$gpu_power_var='N/A'"
    eval "$mem_power_var='N/A'"

    # Read from continuous powermetrics
    local pm_output
    pm_output=$(read_powermetrics_sensor_data 2)
    if [ $? -eq 0 ] && [ -n "$pm_output" ]; then
        # Parse power data
        local parsed_data
        parsed_data=$(parse_powermetrics_power "$pm_output")
        if [ -n "$parsed_data" ]; then
            set -- $parsed_data
            eval "$cpu_power_var='$1'"
            eval "$gpu_power_var='$2'"
            eval "$mem_power_var='$3'"
            return 0
        fi
    fi

    return 1
}