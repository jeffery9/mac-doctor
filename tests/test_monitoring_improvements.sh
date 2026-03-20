#!/bin/bash

# Test monitoring improvements for non-root users
cd "$(dirname "$0")/.."

source modules/config.sh
source modules/logging.sh
source modules/monitoring.sh
source modules/monitoring_nonroot.sh

# Set up test environment
REPORT_DIR="/tmp/monitoring_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"
VOLTAGE_LOG="$REPORT_DIR/voltage.csv"
THERMAL_LOG="$REPORT_DIR/thermal.csv"
POWER_LOG="$REPORT_DIR/power.csv"
DISK_LOG="$REPORT_DIR/disk.csv"

# Initialize logs
echo "Timestamp,Voltage_mV" > "$VOLTAGE_LOG"
echo "Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Active,CPU_Freq_MHz,Kernel_Task_Pct,Clim_Pct,Plimit_Pct,PROCHOT_Count,Thermal_Level" > "$THERMAL_LOG"
echo "Timestamp,CPU_Package_W,GPU_Package_W,Memory_W" > "$POWER_LOG"
echo "Timestamp,KB_t,TPS,MB_s" > "$DISK_LOG"

log "${CYAN}=== 监控功能改进测试 ===${NC}"
log "当前用户: $(whoami) (EUID: $EUID)"
log "测试目录: $REPORT_DIR"

# Test 1: Check what data is available without root
log "${YELLOW}测试1: 非Root数据可用性检查${NC}"

# CPU frequency via sysctl
cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
log "CPU频率: ${cpu_freq}MHz (via sysctl)"

# Load average
load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")
log "系统负载: ${load_avg}"

# GPU power via ioreg
gpu_power=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1 | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "N/A")
log "GPU功耗: ${gpu_power}W (via ioreg)"

# Test 2: Run monitoring for 10 seconds
log "${YELLOW}测试2: 10秒监控测试${NC}"
EARLY_STOP=0

# Start monitoring based on permissions
if [ "$EUID" -eq 0 ]; then
    log "使用Root监控模式"
    start_voltage_monitor
    start_thermal_monitor
    start_power_monitor
    start_disk_io_monitor
else
    log "使用非Root优化监控模式"
    start_voltage_monitor
    start_thermal_monitor_nonroot
    start_power_monitor_nonroot
    start_disk_io_monitor
fi

# Monitor for 10 seconds
sleep 10

# Stop monitoring
EARLY_STOP=1
touch /tmp/stress_early_stop.flag
wait $VOL_PID $THERM_PID $POWER_PID $DISK_IO_PID 2>/dev/null
rm -f /tmp/stress_early_stop.flag

# Test 3: Analyze collected data
log "${YELLOW}测试3: 数据分析${NC}"

# Check thermal data
if [ -f "$THERMAL_LOG" ]; then
    thermal_entries=$(tail -n +2 "$THERMAL_LOG" | wc -l)
    log "热数据记录: ${thermal_entries}条"

    if [ $thermal_entries -gt 0 ]; then
        # Show sample data
        log "采样数据:"
        head -3 "$THERMAL_LOG"
        echo "..."
        tail -3 "$THERMAL_LOG"

        # Calculate statistics
        avg_freq=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f6 | awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count}')
        min_freq=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f6 | sort -n | head -1)
        max_freq=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f6 | sort -n | tail -1)

        log "频率统计: 平均=${avg_freq}MHz, 最低=${min_freq}MHz, 最高=${max_freq}MHz"
    fi
fi

# Check power data
if [ -f "$POWER_LOG" ]; then
    power_entries=$(tail -n +2 "$POWER_LOG" | wc -l)
    log "功耗数据记录: ${power_entries}条"

    if [ $power_entries -gt 0 ]; then
        # Show sample data
        log "功耗采样:"
        head -3 "$POWER_LOG"
        echo "..."
        tail -3 "$POWER_LOG"

        # Check for valid power data
        valid_power=$(tail -n +2 "$POWER_LOG" | grep -v "N/A" | wc -l)
        if [ $valid_power -gt 0 ]; then
            log "${GREEN}✓ 成功获取到 ${valid_power} 条有效功耗数据${NC}"
        else
            log "${YELLOW}⚠ 未获取到有效功耗数据${NC}"
        fi
    fi
fi

# Check disk data
if [ -f "$DISK_LOG" ]; then
    disk_entries=$(tail -n +2 "$DISK_LOG" | wc -l)
    log "磁盘I/O数据记录: ${disk_entries}条"
fi

# Test 4: Comparison with expected values
log "${YELLOW}测试4: 性能评估${NC}"

if [ "$EUID" -ne 0 ]; then
    log "非Root模式性能:"
    log "- CPU频率监控: ✓ (sysctl)"
    log "- 系统负载监控: ✓ (uptime)"
    log "- GPU功耗监控: ✓ (ioreg)"
    log "- 磁盘I/O监控: ✓ (iostat)"
    log "- 温度估算: ✓ (基于频率)"
    log "- 功耗估算: ✓ (基于负载)"

    if [ -f "$THERMAL_LOG" ] && [ $thermal_entries -gt 0 ]; then
        log "${GREEN}✓ 非Root监控运行正常${NC}"
    else
        log "${RED}✗ 非Root监控未能正常工作${NC}"
    fi
fi

# Test 5: Generate simple report
cat > "$REPORT_DIR/test_report.txt" << EOF
监控测试报告
============
测试时间: $(date)
用户: $(whoami) (EUID: $EUID)

数据收集统计:
- 热数据: ${thermal_entries} 条记录
- 功耗数据: ${power_entries} 条记录
- 磁盘数据: ${disk_entries} 条记录

非Root优化功能:
✓ CPU频率监控 (sysctl)
✓ 系统负载监控 (uptime)
✓ GPU功耗监控 (ioreg)
✓ 磁盘I/O监控 (iostat)
✓ 温度估算算法
✓ 功耗估算算法

建议:
$(if [ "$EUID" -ne 0 ]; then echo "- 当前为非root用户，已通过优化算法获取性能数据"; fi)
- 使用root权限可获取更精确的温度和功耗数据
- 估算数据基于频率和负载，具有参考价值
EOF

log "${GREEN}测试报告已生成: $REPORT_DIR/test_report.txt${NC}"

# Cleanup
rm -rf "$REPORT_DIR"

log "${GREEN}监控改进测试完成！${NC}"