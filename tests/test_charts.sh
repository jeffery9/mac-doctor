#!/bin/bash

# Test chart generation with existing data
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source required modules
source "$SCRIPT_DIR/modules/config.sh"
source "$SCRIPT_DIR/modules/logging.sh"
source "$SCRIPT_DIR/modules/charting.sh"

# Set report directory to existing data
REPORT_DIR="/tmp/stress_diag_20260320_165433"
VOLTAGE_LOG="$REPORT_DIR/voltage_curve.csv"
THERMAL_LOG="$REPORT_DIR/thermal_log.csv"
DISK_LOG="$REPORT_DIR/disk_log.csv"
POWER_LOG="$REPORT_DIR/power_log.csv"

echo "Testing chart generation with data from: $REPORT_DIR"

# Generate all charts
generate_all_charts

echo "Chart generation test completed!"
echo "Check directory: $REPORT_DIR for generated PNG files"