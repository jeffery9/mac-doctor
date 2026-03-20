#!/bin/bash

# Debug powermetrics output
log() {
    echo -e "$@"
}

log "${CYAN}=== Powermetrics 调试测试 ===${NC}"

# Test 1: Check available samplers
log "${YELLOW}测试1: 检查可用采样器${NC}"
powermetrics --help | grep -A 20 "samplers" || echo "Help not available"

# Test 2: Basic powermetrics call
log "${YELLOW}测试2: 基本powermetrics调用${NC}"
timeout 5s powermetrics -n 1 -i 500 --samplers smc 2>&1 | head -20

# Test 3: Power samplers test
log "${YELLOW}测试3: 电源采样器测试${NC}"
for sampler in power cpu_power gpu_power smc; do
    log "测试采样器: $sampler"
    output=$(timeout 3s powermetrics -n 1 -i 500 --samplers $sampler 2>&1)
    if echo "$output" | grep -q "Power\|W\|功耗"; then
        echo "✓ $sampler 采样器返回电源数据"
        echo "$output" | grep -i "power\|W" | head -3
    else
        echo "✗ $sampler 采样器无电源数据"
    fi
    echo "---"
done

# Test 4: Check system load impact
log "${YELLOW}测试4: 系统负载对powermetrics的影响${NC}"

# Idle state
log "空闲状态:"
load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}')
echo "负载: $load_avg"
timeout 3s powermetrics -n 1 -i 500 --samplers smc 2>&1 | grep -i "power\|W" | head -5 || echo "无电源数据"

# High load state
log "高负载状态(启动CPU压力):"
(
    while true; do
        echo "scale=5000; 4*a(1)" | bc -l > /dev/null 2>&1
    done
) &
STRESS_PID=$!
sleep 2

load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}')
echo "负载: $load_avg"
echo "运行powermetrics..."
timeout 5s powermetrics -n 1 -i 500 --samplers smc 2>&1 | tee /tmp/pm_debug_output.txt | grep -i "power\|W" | head -10 || echo "无电源数据"

# Kill stress
kill -9 $STRESS_PID 2>/dev/null || true

# Analyze output
log "${YELLOW}分析输出文件:${NC}"
if [ -f /tmp/pm_debug_output.txt ]; then
    echo "文件大小: $(wc -c < /tmp/pm_debug_output.txt) bytes"
    echo "包含'Power'的行数: $(grep -c -i "power" /tmp/pm_debug_output.txt 2>/dev/null || echo 0)"
    echo "包含'W'的行数: $(grep -c "W" /tmp/pm_debug_output.txt 2>/dev/null || echo 0)"

    log "${YELLOW}电源相关数据样本:${NC}"
    grep -i "power\|W" /tmp/pm_debug_output.txt | head -10
fi

# Test 5: Alternative power sources
log "${YELLOW}测试5: 替代电源数据源${NC}"
log "ioreg GPU power:"
ioreg -l 2>/dev/null | grep -i "total power" | head -2

log "pmset电源信息:"
pmset -g batt 2>/dev/null | grep -i "power\|watt"

# Cleanup
rm -f /tmp/pm_debug_output.txt
log "${GREEN}调试完成！${NC}"