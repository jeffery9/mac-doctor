#!/bin/bash

# Debug CPU frequency monitoring issues
echo "=== CPU频率监控问题调试 ==="
echo ""

# 1. Check current frequency methods
echo "1. 检查当前频率获取方法:"
echo "sysctl hw.cpufrequency:"
sysctl hw.cpufrequency 2>/dev/null | awk '{printf "%.0f MHz\n", $1/1000000}'
echo "sysctl hw.cpufrequency_max:"
sysctl hw.cpufrequency_max 2>/dev/null | awk '{printf "%.0f MHz\n", $1/1000000}'
echo ""

# 2. Check if frequency changes under load
echo "2. 检查负载下的频率变化:"
echo "当前负载:"
uptime
echo ""
echo "开始CPU压力测试，观察频率变化..."

# Monitor frequency during stress
echo "时间,sysctl频率,负载"
for i in {1..10}; do
    freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}')
    load=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    echo "$(date +%H:%M:%S),${freq}MHz,${load}"

    # Add some CPU load
    echo "scale=500; 4*a(1)" | bc -l > /dev/null 2>&1 &
    sleep 1
done

# Kill stress processes
pkill -f bc 2>/dev/null || true

echo ""
echo "3. 检查其他频率来源:"
echo "尝试ioreg频率数据:"
ioreg -l 2>/dev/null | grep -i "frequency\|mhz" | head -5

echo ""
echo "4. 检查系统限制:"
echo "CPU速度限制:"
pmset -g therm 2>/dev/null | grep -i "limit\|speed"

echo ""
echo "5. 检查是否被锁定在基础频率:"
echo "CPU信息:"
sysctl machdep.cpu | grep -E "(brand_string|feature|frequency)"

echo ""
echo "=== 可能的原因 ==="
echo "1. CPU被锁定在基础频率（节能模式）"
echo "2. 温度过高导致降频到基础频率"
echo "3. 电源适配器功率不足"
echo "4. SMC限制了CPU性能"
echo "5. 系统设置限制了CPU频率"

echo ""
echo "=== 建议检查 ==="
echo "- 检查系统是否处于节能模式"
echo "- 检查电源适配器是否原装且功率足够"
echo "- 检查CPU温度是否过高"
echo "- 尝试重置SMC"
echo "- 检查是否有软件限制了CPU性能"