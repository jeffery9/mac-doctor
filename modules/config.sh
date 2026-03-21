#!/bin/bash

# ==============================================================================
# 配置模块 - 处理命令行参数和默认配置
# ==============================================================================

# Default Configuration (can be overridden by command line args)
TEST_DURATION=900           # 15 minutes default
PHASE_DURATION=300          # 5 minutes per phase
VOLTAGE_DROP_THRESHOLD=800  # mV voltage drop threshold
TEMP_WARN=85                # °C warning temperature
TEMP_CRIT=95                # °C critical temperature
SAMPLE_INTERVAL=2           # sampling interval (seconds)

# Global flags
VOLTAGE_WARNING=0
THERMAL_WARNING=0
KERNEL_TASK_WARNING=0
KERNEL_ERROR=0
TEST_COMPLETED=0
EARLY_STOP=0
TEST_MODE=""
CURRENT_PHASE=""
PYTHON_MONITOR=true

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--duration)
                TEST_DURATION="$2"
                PHASE_DURATION=$((TEST_DURATION / 3))
                shift 2
                ;;
            -s|--sample-interval)
                SAMPLE_INTERVAL="$2"
                shift 2
                ;;
            -t|--temp-warn)
                TEMP_WARN="$2"
                shift 2
                ;;
            -c|--temp-crit)
                TEMP_CRIT="$2"
                shift 2
                ;;
            -v|--voltage-threshold)
                VOLTAGE_DROP_THRESHOLD="$2"
                shift 2
                ;;
            --python-monitor)
                PYTHON_MONITOR=true
                shift
                ;;
            --shell-monitor)
                PYTHON_MONITOR=false
                shift
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Initialize report directory and log files
initialize_report_dir() {
    REPORT_DIR="/tmp/stress_diag_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$REPORT_DIR"
    LOG_FILE="$REPORT_DIR/stress_summary.log"
    VOLTAGE_LOG="$REPORT_DIR/voltage_curve.csv"
    KERNEL_LOG="$REPORT_DIR/kernel_errors.log"
    THERMAL_LOG="$REPORT_DIR/thermal_log.csv"
    POWER_LOG="$REPORT_DIR/power_log.csv"
    DISK_LOG="$REPORT_DIR/disk_log.csv"
}