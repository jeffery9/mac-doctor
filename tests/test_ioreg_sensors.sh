#!/bin/bash

# Test ioreg SMC sensor data availability
echo "=== ioreg SMC传感器数据测试 ==="
echo ""

# Test 1: Check what SMC keys are available
echo "测试1: SMC传感器键值扫描"
echo "扫描温度相关键值..."
ioreg -l 2>/dev/null | grep -i "temperature\|temp" | head -20

echo ""
echo "扫描风扇相关键值..."
ioreg -l 2>/dev/null | grep -i "fan\|rpm" | head -20

echo ""
echo "扫描电源相关键值..."
ioreg -l 2>/dev/null | grep -i "power\|watt\|voltage\|current" | head -20

echo ""
echo "扫描CPU相关键值..."
ioreg -l 2>/dev/null | grep -i "cpu\|processor" | head -20

echo ""
echo "=== 特定传感器数据提取 ==="

# Test 2: Try to extract specific sensor data
echo "GPU温度:"
ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' -A 20 | grep -i temperature | head -5

echo ""
echo "CPU频率相关:"
ioreg -l 2>/dev/null | grep -i "frequency\|mhz" | head -10

echo ""
echo "系统负载:"
ioreg -l 2>/dev/null | grep -i "load\|busy" | head -10

echo ""
echo "电源状态:"
ioreg -l 2>/dev/null | grep -i "power\|ac\|battery" | head -10

echo ""
echo "=== 尝试获取具体数值 ==="

# Test 3: Get actual values if available
echo "GPU功耗:"
gpu_power=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1 | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+')
echo "结果: ${gpu_power:-"无法获取"}"

echo ""
echo "GPU温度:"
gpu_temp=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "temperature" | head -1 | grep -oE '[0-9]+')
echo "结果: ${gpu_temp:-"无法获取"}"

echo ""
echo "风扇转速:"
fan_rpm=$(ioreg -l 2>/dev/null | grep -i "fan.*rpm" | head -1 | grep -oE '[0-9]+')
echo "结果: ${fan_rpm:-"无法获取"}"

echo ""
echo "=== SMC键值探索 ==="
# Look for SMC-related data
ioreg -l 2>/dev/null | grep -E "SMCD|smc|IOHWSensor" | head -10

echo ""
echo "测试完成！"