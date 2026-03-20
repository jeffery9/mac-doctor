#!/bin/bash

# Test script for high-load power monitoring
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source modules
source "$SCRIPT_DIR/modules/config.sh"
source "$SCRIPT_DIR/modules/logging.sh"
source "$SCRIPT_DIR/modules/monitoring.sh"

# Set up test environment
REPORT_DIR="/tmp/high_load_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"
POWER_LOG="$REPORT_DIR/power_test.csv"
THERMAL_LOG="$REPORT_DIR/thermal_test.csv"

# Initialize logs
echo "Timestamp,CPU_Package_W,GPU_Package_W,Memory_W" > "$POWER_LOG"
echo "Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Active,CPU_Freq_MHz,Kernel_Task_Pct,Clim_Pct,Plimit_Pct,PROCHOT_Count,Thermal_Level" > "$THERMAL_LOG"

log "${CYAN}=== 高负载功耗监控测试 ===${NC}"
log "测试目录: $REPORT_DIR"

# Test 1: Idle state monitoring
log "${YELLOW}测试1: 空闲状态监控 (10秒)${NC}"
EARLY_STOP=0
start_thermal_monitor &
sleep 2
start_power_monitor &
sleep 10
EARLY_STOP=1
touch /tmp/stress_early_stop.flag
wait $THERM_PID 2>/dev/null
wait $POWER_PID 2>/dev/null
rm -f /tmp/stress_early_stop.flag

# Check results
if [ -f "$POWER_LOG" ]; then
    power_entries=$(tail -n +2 "$POWER_LOG" | wc -l)
    valid_power=$(tail -n +2 "$POWER_LOG" | grep -v "N/A" | wc -l)
    log "功耗数据: ${power_entries}条记录, ${valid_power}条有效数据"

    if [ $valid_power -gt 0 ]; then
        avg_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -v "N/A" | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count}')
        log "${GREEN}✓ 空闲状态平均功耗: ${avg_power}W${NC}"
    fi
fi

# Test 2: High load monitoring
log "${YELLOW}测试2: 高负载状态监控 (20秒)${NC}"
EARLY_STOP=0

# Start CPU stress in background
(
    while true; do
        openssl speed -multi 4 2>/dev/null | head -20 > /dev/null
        if [ -f /tmp/stress_early_stop.flag ]; then
            break
        fi
    done
) &
STRESS_PID=$!

# Start monitoring
start_thermal_monitor &
sleep 2
start_power_monitor &
sleep 20

# Stop stress
kill -9 $STRESS_PID 2>/dev/null || true
EARLY_STOP=1
touch /tmp/stress_early_stop.flag
wait $THERM_PID 2>/dev/null
wait $POWER_PID 2>/dev/null
rm -f /tmp/stress_early_stop.flag

# Check high load results
log "${GREEN}=== 高负载测试结果 ===${NC}"
if [ -f "$POWER_LOG" ]; then
    power_entries=$(tail -n +2 "$POWER_LOG" | wc -l)
    valid_power=$(tail -n +2 "$POWER_LOG" | grep -v "N/A" | wc -l)
    log "总功耗数据: ${power_entries}条记录, ${valid_power}条有效数据"

    if [ $valid_power -gt 0 ]; then
        # Calculate statistics
        max_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -v "N/A" | sort -n | tail -1)
        min_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -v "N/A" | sort -n | head -1)
        avg_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -v "N/A" | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count}')

        log "${GREEN}✓ 功耗统计:${NC}"
        log "  - 最高功耗: ${max_power}W"
        log "  - 最低功耗: ${min_power}W"
        log "  - 平均功耗: ${avg_power}W"

        # Check thermal data
        if [ -f "$THERMAL_LOG" ]; then
            thermal_entries=$(tail -n +2 "$THERMAL_LOG" | wc -l)
            log "热数据: ${thermal_entries}条记录"

            # Show sample data
            log "${CYAN}采样数据:${NC}"
            tail -3 "$POWER_LOG" | while IFS=',' read -r ts cpu gpu mem; do
                echo "  $ts: CPU=${cpu}W, GPU=${gpu}W, MEM=${mem}W"
            done
        fi

        # Success rate
        success_rate=$(echo "scale=1; $valid_power * 100 / $power_entries" | bc -l 2>/dev/null || echo "0")
        log "${GREEN}✓ 数据抓取成功率: ${success_rate}%${NC}"

        if (( $(echo "$success_rate > 80" | bc -l) )); then
            log "${GREEN}✓ 高负载功耗监控运行正常！${NC}"
        else
            log "${YELLOW}⚠ 数据抓取成功率偏低，需要优化${NC}"
        fi
    else
        log "${RED}✗ 未获取到有效的功耗数据${NC}"
    fi
fi

# Cleanup
rm -rf "$REPORT_DIR"
log "${GREEN}高负载功耗监控测试完成！${NC}"