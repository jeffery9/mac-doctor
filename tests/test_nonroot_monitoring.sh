#!/bin/bash

# Test non-root monitoring capabilities

echo "=== 非Root权限监控测试 ==="
echo "当前用户: $(whoami)"
echo "EUID: $EUID"
echo ""

# Test 1: Check available tools
echo "测试1: 检查可用工具"
echo "- sysctl: $(which sysctl 2>/dev/null || echo '未找到')"
echo "- ioreg: $(which ioreg 2>/dev/null || echo '未找到')"
echo "- vm_stat: $(which vm_stat 2>/dev/null || echo '未找到')"
echo "- iostat: $(which iostat 2>/dev/null || echo '未找到')"
echo "- powermetrics: $(which powermetrics 2>/dev/null || echo '未找到')"
echo ""

# Test 2: Basic system info
echo "测试2: 基础系统信息"
echo "CPU型号: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '无法获取')"
echo "CPU核心数: $(sysctl -n hw.ncpu 2>/dev/null || echo '无法获取')"
echo "内存总量: $(echo "$(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024" | bc)GB"
echo ""

# Test 3: Frequency monitoring
echo "测试3: 频率监控"
echo "当前CPU频率:"
sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f MHz\n", $1/1000000}' || echo "无法获取"
echo "最大CPU频率:"
sysctl -n hw.cpufrequency_max 2>/dev/null | awk '{printf "%.0f MHz\n", $1/1000000}' || echo "无法获取"
echo ""

# Test 4: ioreg power data
echo "测试4: ioreg电源数据"
echo "GPU总功耗:"
ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1 | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "无法获取"
echo "GPU温度:"
ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "temperature" | head -1 | grep -oE '[0-9]+' || echo "无法获取"
echo ""

# Test 5: vm_stat memory info
echo "测试5: 内存信息"
vm_stat 2>/dev/null | head -5 || echo "vm_stat不可用"
echo ""

# Test 6: iostat disk info
echo "测试6: 磁盘I/O信息"
if disk=$(diskutil list | awk '/internal, physical/ {print $1; exit}' 2>/dev/null); then
    echo "系统磁盘: $disk"
    iostat -d 1 1 "$disk" 2>/dev/null | tail -1 || echo "iostat不可用"
else
    echo "无法找到系统磁盘"
fi
echo ""

# Test 7: Load average
echo "测试7: 系统负载"
uptime
echo ""

# Test 8: Try powermetrics (will likely fail without sudo)
echo "测试8: powermetrics测试(非root)"
if [ "$EUID" -ne 0 ]; then
    echo "尝试运行powermetrics(预期失败):"
    powermetrics -n 1 -i 1000 --samplers smc 2>&1 | head -5 || echo "powermetrics需要root权限"
fi
echo ""

# Test 9: Simulate monitoring loop
echo "测试9: 模拟监控循环(5秒)"
echo "时间,CPU频率,负载,GPU功耗"
for i in {1..5}; do
    freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
    load=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")
    gpu_power=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1 | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "N/A")
    echo "$(date +%H:%M:%S),${freq}MHz,${load},${gpu_power}W"
    sleep 1
done

echo ""
echo "=== 测试完成 ==="
echo "建议:"
if [ "$EUID" -ne 0 ]; then
    echo "- 当前为非root用户，温度和频率数据受限"
    echo "- GPU功耗可通过ioreg获取"
    echo "- CPU频率可通过sysctl获取基础信息"
    echo "- 建议运行: sudo $0 获取完整数据"
fi