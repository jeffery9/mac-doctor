#!/bin/bash

# Python-based monitoring module for macOS stress test suite
# Provides shell-to-Python bridge for hardware monitoring

# Source the configuration
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Global variables
PYTHON_MONITOR_PID=""
PYTHON_MONITOR_LOG="/tmp/python_monitor.log"

# Check if Python monitoring is available
check_python_monitor_available() {

    # Check if Python 3 is available
    if ! command -v python3 &> /dev/null; then
        log "Python 3 not found, Python monitoring unavailable"
        return 1
    fi

    # Use the global SCRIPT_DIR from the main script
    # If not available, fall back to current directory
    local MAIN_SCRIPT_DIR="${SCRIPT_DIR:-$(pwd)}"
    local PYTHON_MONITOR_SCRIPT="$MAIN_SCRIPT_DIR/python_monitor_core.py"

    # Check if our Python monitor script exists
    if [[ ! -f "$PYTHON_MONITOR_SCRIPT" ]]; then
        log "Python monitor core script not found: $PYTHON_MONITOR_SCRIPT"
        return 1
    fi

    # Test Python imports
    if ! python3 -c "import sys, csv, json, subprocess, argparse, signal" &> /dev/null; then
        log "Python dependencies missing"
        return 1
    fi

    return 0
}

# Start thermal monitoring with Python
start_thermal_monitor_python() {
    # Use global variables instead of parameters
    local output_file="$THERMAL_LOG"
    local interval="$SAMPLE_INTERVAL"
    local log_prefix=""

    log "Starting Python thermal monitor (output: $output_file, interval: ${interval}s)"

    # Create temporary directory for Python logs
    local temp_dir=$(mktemp -d)
    local python_thermal_log="$temp_dir/thermal_log.csv"
    local python_power_log="$temp_dir/power_log.csv"

    # Use the global SCRIPT_DIR from the main script
    local MAIN_SCRIPT_DIR="${SCRIPT_DIR:-$(pwd)}"
    local PYTHON_MONITOR_SCRIPT="$MAIN_SCRIPT_DIR/python_monitor_core.py"

    # Start Python monitor in background with real-time output
    python3 "$PYTHON_MONITOR_SCRIPT" \
        --thermal-log "$python_thermal_log" \
        --power-log "$python_power_log" \
        --interval "$interval" \
        --show-realtime &

    PYTHON_MONITOR_PID=$!

    # Give Python monitor time to start
    sleep 2

    # Check if Python monitor started successfully
    if ! kill -0 $PYTHON_MONITOR_PID 2>/dev/null; then
        log "Python monitor failed to start, check $PYTHON_MONITOR_LOG"
        rm -rf "$temp_dir"
        return 1
    fi

    # Start converter process to maintain compatibility
    {
        # Wait for Python to generate first line
        sleep 3

        # Copy CSV header first
        if [[ -f "$python_thermal_log" ]]; then
            head -n 1 "$python_thermal_log" > "$output_file"
        else
            # Write default header if file not ready
            echo "Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Activity_%,CPU_Freq_MHz,Kernel_Task_%,CPU_Speed_Limit_%,CPU_Plimit,Prochots,Thermal_Level" > "$output_file"
        fi

        # Tail the Python output and convert to our format
        tail -n +2 -f "$python_thermal_log" 2>/dev/null | while IFS= read -r line; do
            if [[ -n "$line" && "$line" != "Timestamp,"* ]]; then
                echo "$line" >> "$output_file"
            fi
        done
    } &

    local converter_pid=$!

    # Store PIDs in global variables for cleanup
    THERM_PID=$PYTHON_MONITOR_PID
    PYTHON_THERMAL_CONVERTER_PID=$converter_pid
    PYTHON_TEMP_DIR=$temp_dir

    log "Python thermal monitor started (PID: $PYTHON_MONITOR_PID)"
    return 0
}

# Start power monitoring with Python
start_power_monitor_python() {
    # Use global variables instead of parameters
    local output_file="$POWER_LOG"
    local interval="$SAMPLE_INTERVAL"
    local log_prefix=""

    log "Starting Python power monitor (output: $output_file, interval: ${interval}s)"

    # Use the same temp directory as thermal monitoring
    local temp_dir="$PYTHON_TEMP_DIR"
    if [[ -z "$temp_dir" ]] || [[ ! -d "$temp_dir" ]]; then
        # Fallback: create new temp directory if thermal didn't start
        temp_dir=$(mktemp -d)
    fi

    local python_power_log="$temp_dir/power_log.csv"

    # Power monitoring is already running with thermal monitor
    # Just need to convert the format
    {
        # Wait for Python to generate first line
        sleep 3

        # Copy CSV header first
        if [[ -f "$python_power_log" ]]; then
            head -n 1 "$python_power_log" > "$output_file"
        else
            # Write default header if file not ready
            echo "Timestamp,CPU_Power_W,GPU_Power_W,Memory_Power_W" > "$output_file"
        fi

        # Tail the Python output
        tail -n +2 -f "$python_power_log" 2>/dev/null | while IFS= read -r line; do
            if [[ -n "$line" && "$line" != "Timestamp,"* ]]; then
                echo "$line" >> "$output_file"
            fi
        done
    } &

    local converter_pid=$!

    # Store power converter PID in global variable
    PYTHON_POWER_CONVERTER_PID=$converter_pid

    log "Python power monitor converter started"
    return 0
}

# Stop Python monitoring
stop_python_monitor() {
    # Stop Python monitor process
    if [[ -n "$PYTHON_MONITOR_PID" ]] && kill -0 "$PYTHON_MONITOR_PID" 2>/dev/null; then
        log "Stopping Python monitor (PID: $PYTHON_MONITOR_PID)"
        kill -TERM "$PYTHON_MONITOR_PID" 2>/dev/null
        sleep 1
        kill -KILL "$PYTHON_MONITOR_PID" 2>/dev/null
    fi

    # Stop converter processes
    if [[ -n "$PYTHON_THERMAL_CONVERTER_PID" ]] && kill -0 "$PYTHON_THERMAL_CONVERTER_PID" 2>/dev/null; then
        kill -TERM "$PYTHON_THERMAL_CONVERTER_PID" 2>/dev/null
        sleep 1
        kill -KILL "$PYTHON_THERMAL_CONVERTER_PID" 2>/dev/null
    fi

    if [[ -n "$PYTHON_POWER_CONVERTER_PID" ]] && kill -0 "$PYTHON_POWER_CONVERTER_PID" 2>/dev/null; then
        kill -TERM "$PYTHON_POWER_CONVERTER_PID" 2>/dev/null
        sleep 1
        kill -KILL "$PYTHON_POWER_CONVERTER_PID" 2>/dev/null
    fi

    # Clean up temporary directory
    if [[ -n "$PYTHON_TEMP_DIR" ]] && [[ -d "$PYTHON_TEMP_DIR" ]]; then
        rm -rf "$PYTHON_TEMP_DIR"
    fi

    # Clear PID variables
    PYTHON_MONITOR_PID=""
    PYTHON_THERMAL_CONVERTER_PID=""
    PYTHON_POWER_CONVERTER_PID=""
    PYTHON_TEMP_DIR=""
}

# Check Python monitor health
check_python_monitor_health() {
    if [[ -n "$PYTHON_MONITOR_PID" ]]; then
        if ! kill -0 "$PYTHON_MONITOR_PID" 2>/dev/null; then
            log "Python monitor process died unexpectedly"
            return 1
        fi
    fi
    return 0
}

# Fallback to shell monitoring
fallback_to_shell_monitor() {
    log "Falling back to shell-based monitoring"
    stop_python_monitor

    # Re-enable shell monitoring
    source "$SCRIPT_DIR/monitoring.sh"
    MONITORING_MODULE="shell"
}