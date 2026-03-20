#!/bin/bash

# Test alternative monitoring
cd "$(dirname "$0")/.."

source modules/config.sh
source modules/logging.sh
source modules/monitoring_alt.sh

# Set up test
REPORT_DIR="/tmp/alt_monitor_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"
THERMAL_LOG="$REPORT_DIR/thermal_alt.csv"
POWER_LOG="$REPORT_DIR/power_alt.csv"

# Initialize logs
echo "Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Active,CPU_Freq_MHz,Kernel_Task_Pct,Clim_Pct,Plimit_Pct,PROCHOT_Count,Thermal_Level" > "$THERMAL_LOG"
echo "Timestamp,CPU_Package_W,GPU_Package_W,Memory_W" > "$POWER_LOG"

log "${CYAN}=== 替代监控方案测试 ===${NC}"
log "测试目录: $REPORT_DIR"
log "当前用户: $(whoami) (EUID: $EUID)"

# Test alternative monitoring for 10 seconds
EARLY_STOP=0
start_thermal_monitor_alt &
sleep 2
start_power_monitor_alt &
sleep 10

EARLY_STOP=1
touch /tmp/stress_early_stop.flag
wait $THERM_PID 2>/dev/null
wait $POWER_PID 2>/dev/null
rm -f /tmp/stress_early_stop.flag

# Analyze results
log "${GREEN}=== 测试结果 ===${NC}"

if [ -f "$THERMAL_LOG" ]; then
    entries=$(tail -n +2 "$THERMAL_LOG" | wc -l)
    log "热数据记录: ${entries}条"

    if [ $entries -gt 0 ]; then
        # Show sample data
        log "采样数据:"
        head -3 "$THERMAL_LOG"
        echo "..."
        tail -2 "$THERMAL_LOG"

        # Extract actual sensor data
        latest=$(tail -1 "$THERMAL_LOG")
        cpu_temp=$(echo "$latest" | cut -d',' -f2)
        gpu_temp=$(echo "$latest" | cut -d',' -f3)
        fan_rpm=$(echo "$latest" | cut -d',' -f4)
        gpu_power=$(echo "$latest" | cut -d',' -f5)
        cpu_freq=$(echo "$latest" | cut -d',' -f6)

        log "最新数据:"
        log "  CPU温度: ${cpu_temp}°C"
        log "  GPU温度: ${gpu_temp}°C"
        log "  风扇转速: ${fan_rpm}RPM"
        log "  GPU功耗: ${gpu_power}W"
        log "  CPU频率: ${cpu_freq}MHz"

        # Check if we got real data
        if [ "$fan_rpm" != "0" ] && [ -n "$fan_rpm" ]; then
            log "${GREEN}✓ 成功获取风扇转速数据${NC}"
        fi

        if [ "$gpu_power" != "0" ] && [ -n "$gpu_power" ]; then
            log "${GREEN}✓ 成功获取GPU功耗数据${NC}"
        fi

        if [ "$gpu_temp" != "0" ] && [ -n "$gpu_temp" ]; then
            log "${GREEN}✓ 成功获取GPU温度数据${NC}"
        fi
    fi
fi

if [ -f "$POWER_LOG" ]; then
    power_entries=$(tail -n +2 "$POWER_LOG" | wc -l)
    log "功耗数据记录: ${power_entries}条"

    if [ $power_entries -gt 0 ]; then
        latest_power=$(tail -1 "$POWER_LOG")
        cpu_power=$(echo "$latest_power" | cut -d',' -f2)
        gpu_power=$(echo "$latest_power" | cut -d',' -f3)

        log "功耗数据:"
        log "  CPU功耗: ${cpu_power}W"
        log "  GPU功耗: ${gpu_power}W"

        valid_power=$(tail -n +2 "$POWER_LOG" | grep -v "N/A" | wc -l)
        if [ $valid_power -gt 0 ]; then
            log "${GREEN}✓ 成功获取 ${valid_power} 条有效功耗数据${NC}"
        fi
    fi
fi

# Cleanup
rm -rf "$REPORT_DIR"

log "${GREEN}替代监控测试完成！${NC}"