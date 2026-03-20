#!/bin/bash

# Extract actual sensor data from ioreg
echo "=== 提取可用传感器数据 ==="
echo ""

# GPU功耗 (已确认可用)
echo "1. GPU功耗:"
gpu_power=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1 | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+')
echo "   结果: ${gpu_power:-"无法获取"}W"
echo ""

# GPU温度 (已确认可用)
echo "2. GPU温度:"
gpu_temp=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -A5 -B5 "temperature" | grep -oE '"Temperature\(C\)"=[0-9]+' | head -1 | grep -oE '[0-9]+')
echo "   结果: ${gpu_temp:-"无法获取"}°C"
echo ""

# 风扇转速 (已确认可用)
echo "3. 风扇转速:"
echo "   风扇百分比:"
fan_pct=$(ioreg -l 2>/dev/null | grep -i '"Fan Speed(%)"' | grep -oE '[0-9]+' | head -1)
echo "   结果: ${fan_pct:-"无法获取"}%"
echo "   风扇RPM:"
fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan Speed(RPM)"' | grep -oE '[0-9]+' | head -1)
echo "   结果: ${fan_rpm:-"无法获取"}RPM"
echo ""

# CPU频率 (通过sysctl)
echo "4. CPU频率:"
cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}')
echo "   结果: ${cpu_freq:-"无法获取"}MHz"
echo ""

# 负载信息
echo "5. 系统负载:"
load_1m=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//')
echo "   1分钟负载: ${load_1m:-"无法获取"}"
echo ""

# 尝试获取CPU温度（多种方式）
echo "6. CPU温度尝试:"
echo "   方式1 - 直接搜索:"
cpu_temp1=$(ioreg -l 2>/dev/null | grep -i "cpu.*temp\|tc0c\|tc0d" | head -5)
echo "   ${cpu_temp1:-"未找到"}"
echo ""
echo "   方式2 - AppleSMC搜索:"
cpu_temp2=$(ioreg -l 2>/dev/null | grep -A5 -B5 AppleSMC | grep -i temp | head -5)
echo "   ${cpu_temp2:-"未找到"}"
echo ""
echo "   方式3 - 估算温度（基于频率）:"
if [ -n "$cpu_freq" ] && [ "$cpu_freq" -lt 2000 ]; then
    est_temp=$((85 + (2000 - cpu_freq) / 50))
elif [ -n "$cpu_freq" ] && [ "$cpu_freq" -lt 2600 ]; then
    est_temp=$((70 + (2600 - cpu_freq) / 30))
else
    est_temp=55
fi
echo "   估算结果: ${est_temp}°C (基于频率${cpu_freq}MHz)"
echo ""

# 电源状态
echo "7. 电源状态:"
power_status=$(pmset -g batt 2>/dev/null | head -3)
echo "   ${power_status:-"无法获取"}"
echo ""

# 电压信息
echo "8. 电压信息:"
voltage_now=$(ioreg -l 2>/dev/null | grep -i "voltage" | grep -oE '[0-9]+' | head -1)
echo "   结果: ${voltage_now:-"无法获取"}mV"
echo ""

echo "=== 可用数据总结 ==="
echo ""
echo "✅ 确认可用的数据:"
[ -n "$gpu_power" ] && echo "  - GPU功耗: ${gpu_power}W"
[ -n "$gpu_temp" ] && echo "  - GPU温度: ${gpu_temp}°C"
[ -n "$fan_pct" ] && echo "  - 风扇百分比: ${fan_pct}%"
[ -n "$fan_rpm" ] && echo "  - 风扇转速: ${fan_rpm}RPM"
[ -n "$cpu_freq" ] && echo "  - CPU频率: ${cpu_freq}MHz"
[ -n "$load_1m" ] && echo "  - 系统负载: ${load_1m}"
echo "  - 估算CPU温度: ${est_temp}°C"
echo ""
echo "⚠️  需要root权限的数据:"
echo "  - CPU精确温度 (powermetrics)"
echo "  - CPU封装功耗 (powermetrics)"
echo "  - 详细热传感器 (powermetrics)"