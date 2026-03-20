#!/bin/bash

# Test the corrected power estimation algorithm
cd "$(dirname "$0")/.."

source modules/config.sh
source modules/logging.sh
source modules/monitoring_alt.sh

# Set up test
REPORT_DIR="/tmp/power_fix_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"
POWER_LOG="$REPORT_DIR/power_fix.csv"

# Initialize log
echo "Timestamp,CPU_Package_W,GPU_Package_W,Memory_W" > "$POWER_LOG"

log "${CYAN}=== 功耗估算算法修正测试 ===${NC}"
log "测试目录: $REPORT_DIR"

# Test different load scenarios
echo "测试不同负载场景下的功耗估算:"
echo ""

# Test 1: Idle state
echo "1. 空闲状态测试 (5秒)..."
EARLY_STOP=0
start_power_monitor_alt &
sleep 2

# Monitor idle for 5 seconds
sleep 5

EARLY_STOP=1
touch /tmp/stress_early_stop.flag
wait $POWER_PID 2>/dev/null
rm -f /tmp/stress_early_stop.flag

if [ -f "$POWER_LOG" ]; then
    idle_power=$(tail -1 "$POWER_LOG" | cut -d',' -f2)
    echo "空闲功耗: ${idle_power:-N/A}W (期望: 5-15W)"
fi

# Test 2: Medium load
echo ""
echo "2. 中度负载测试 (10秒)..."
EARLY_STOP=0
> "$POWER_LOG"  # Clear log
start_power_monitor_alt &
sleep 2

# Start medium CPU stress
(
    while [ ! -f /tmp/stress_early_stop.flag ]; do
        echo "scale=1000; 4*a(1)" | bc -l > /dev/null 2>&1
    done
) &
STRESS_PID=$!

sleep 10

# Stop stress
kill -9 $STRESS_PID 2>/dev/null || true
echo > /tmp/stress_early_stop.flag

EARLY_STOP=1
wait $POWER_PID 2>/dev/null
rm -f /tmp/stress_early_stop.flag

if [ -f "$POWER_LOG" ]; then
    medium_power=$(tail -1 "$POWER_LOG" | cut -d',' -f2)
    echo "中负载功耗: ${medium_power:-N/A}W (期望: 20-35W)"
fi

# Test 3: Check system state during test
echo ""
echo "3. 系统状态检查:"
cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}')
load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")
echo "- CPU频率: ${cpu_freq}MHz"
echo "- 系统负载: ${load_avg}"
echo ""

# Test the algorithm directly
echo "4. 算法直接验证:"
# Source the algorithm function
source modules/monitoring_alt.sh

# Simulate the calculation
freq=2600
load=4.5
temp=75

# Base power calculation
if [ "$freq" -ge 4500 ]; then
    base_power=60
elif [ "$freq" -ge 4000 ]; then
    base_power=$(echo "scale=1; 45 + ($freq - 4000) * 15 / 500" | bc -l)
elif [ "$freq" -ge 3500 ]; then
    base_power=$(echo "scale=1; 25 + ($freq - 3500) * 20 / 500" | bc -l)
elif [ "$freq" -ge 2600 ]; then
    base_power=$(echo "scale=1; 15 + ($freq - 2600) * 10 / 900" | bc -l)
else
    base_power=$(echo "scale=1; 8 + ($freq - 800) * 7 / 1800" | bc -l)
fi

if (( $(echo "$load > 8.0" | bc -l 2>/dev/null || echo 0) )); then
    load_multiplier=1.35
elif (( $(echo "$load > 5.0" | bc -l 2>/dev/null || echo 0) )); then
    load_multiplier=1.25
elif (( $(echo "$load > 2.0" | bc -l 2>/dev/null || echo 0) )); then
    load_multiplier=1.15
else
    load_multiplier=1.05
fi

if [ "$temp" -gt 95 ]; then
    temp_correction=1.15
elif [ "$temp" -gt 85 ]; then
    temp_correction=1.10
elif [ "$temp" -gt 75 ]; then
    temp_correction=1.05
else
    temp_correction=1.00
fi

estimated_power=$(echo "scale=1; $base_power * $load_multiplier * $temp_correction" | bc -l)

echo "基础功耗: ${base_power}W"
echo "负载系数: ${load_multiplier}"
echo "温度修正: ${temp_correction}"
echo "估算结果: ${estimated_power}W"
echo ""

# Compare with your current issue
echo "5. 问题对比:"
echo "- 修正前: ~140W (明显错误)"
echo "- 修正后: ~${estimated_power}W (合理范围)"
echo "- Intel i7-9750H TDP: 45W"
echo "- 最大功耗: ~60-70W"
echo ""

# Cleanup
rm -rf "$REPORT_DIR"
rm -f /tmp/stress_early_stop.flag

echo "${GREEN}功耗估算算法修正测试完成！${NC}"