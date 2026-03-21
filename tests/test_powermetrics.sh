#!/bin/bash

# Test script for improved powermetrics implementation
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source required modules
source "$SCRIPT_DIR/../modules/config.sh"
source "$SCRIPT_DIR/../modules/logging.sh"
source "$SCRIPT_DIR/../modules/monitoring.sh"

# Set up test environment
REPORT_DIR="/tmp/powermetrics_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"
VOLTAGE_LOG="$REPORT_DIR/voltage_curve.csv"
THERMAL_LOG="$REPORT_DIR/thermal_log.csv"
POWER_LOG="$REPORT_DIR/power_log.csv"
DISK_LOG="$REPORT_DIR/disk_log.csv"
KERNEL_LOG="$REPORT_DIR/kernel_errors.log"

# Initialize logs
initialize_csv_logs

# Set test parameters
SAMPLE_INTERVAL=2
EARLY_STOP=0

log "${CYAN}=== 测试改进的 Powermetrics 实现 ===${NC}"
log "测试目录: $REPORT_DIR"
log "采样间隔: ${SAMPLE_INTERVAL}秒"

# Test thermal monitoring with powermetrics
log "${YELLOW}测试热监控 (powermetrics)...${NC}"
start_thermal_monitor
sleep 5
EARLY_STOP=1
touch /tmp/stress_early_stop.flag
wait $THERM_PID
rm -f /tmp/stress_early_stop.flag

# Test power monitoring with powermetrics
log "${YELLOW}测试功耗监控 (powermetrics)...${NC}"
EARLY_STOP=0
start_power_monitor
sleep 5
EARLY_STOP=1
touch /tmp/stress_early_stop.flag
wait $POWER_PID
rm -f /tmp/stress_early_stop.flag

# Check results
log "${GREEN}=== 测试结果 ===${NC}"

if [ -f "$THERMAL_LOG" ]; then
    log "热监控日志已生成:"
    tail -5 "$THERMAL_LOG"

    # Check if we got temperature data
    temp_data=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f2 | grep -E '^[0-9]+$' | head -1)
    if [ -n "$temp_data" ] && [ "$temp_data" -gt 0 ]; then
        log "${GREEN}✓ 成功获取 CPU 温度数据: ${temp_data}°C${NC}"
    else
        log "${YELLOW}⚠ 未获取到有效的 CPU 温度数据${NC}"
    fi

    # Check frequency data
    freq_data=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f6 | grep -E '^[0-9]+$' | head -1)
    if [ -n "$freq_data" ] && [ "$freq_data" -gt 0 ]; then
        log "${GREEN}✓ 成功获取 CPU 频率数据: ${freq_data}MHz${NC}"
    else
        log "${YELLOW}⚠ 未获取到有效的 CPU 频率数据${NC}"
    fi
fi

if [ -f "$POWER_LOG" ]; then
    log ""
    log "功耗监控日志已生成:"
    tail -5 "$POWER_LOG"

    # Check power data
    cpu_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -E '^[0-9.]+$' | head -1)
    gpu_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f3 | grep -E '^[0-9.]+$' | head -1)

    if [ -n "$cpu_power" ] && echo "$cpu_power" | grep -qE '^[0-9.]+$'; then
        log "${GREEN}✓ 成功获取 CPU 功耗数据: ${cpu_power}W${NC}"
    else
        log "${YELLOW}⚠ 未获取到有效的 CPU 功耗数据${NC}"
    fi

    if [ -n "$gpu_power" ] && echo "$gpu_power" | grep -qE '^[0-9.]+$'; then
        log "${GREEN}✓ 成功获取 GPU 功耗数据: ${gpu_power}W${NC}"
    else
        log "${YELLOW}⚠ 未获取到有效的 GPU 功耗数据${NC}"
    fi
fi

# Clean up
rm -rf "$REPORT_DIR"

log "${GREEN}Powermetrics 测试完成！${NC}"