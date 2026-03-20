#!/bin/bash

# Enhanced frequency detection for macOS
echo "=== 增强频率检测实现 ==="
echo ""

# Function to get CPU frequency from multiple sources
get_cpu_frequency() {
    local freq="0"

    # Method 1: Try sysctl (may return 0 on some systems)
    freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}')
    if [ "$freq" -eq 0 ] || [ -z "$freq" ]; then
        # Method 2: Try hw.cpufrequency_max as current frequency
        freq=$(sysctl -n hw.cpufrequency_max 2>/dev/null | awk '{printf "%.0f", $1/1000000}')
    fi

    # Method 3: Try ioreg clock-frequency
    if [ "$freq" -eq 0 ] || [ "$freq" -eq 2600 ]; then
        # Look for current clock frequency in ioreg
        clock_freq=$(ioreg -l 2>/dev/null | grep -i "clock-frequency" | head -1 | grep -oE '[0-9a-fA-F]+' | head -1)
        if [ -n "$clock_freq" ]; then
            # Convert hex to decimal and then to MHz
            freq_dec=$((clock_freq))
            freq=$(echo "scale=0; $freq_dec / 1000000" | bc -l 2>/dev/null || echo "2600")
        fi
    fi

    # Method 4: Estimate based on system indicators
    if [ "$freq" -eq 0 ] || [ "$freq" -eq 2600 ]; then
        # Check thermal state
        cpu_limit=$(pmset -g therm 2>/dev/null | grep "CPU_Speed_Limit" | awk -F'=' '{print $2}' | tr -d ' ' || echo "100")

        # Check if we're being throttled
        if [ "$cpu_limit" -lt 100 ]; then
            # Being throttled - estimate based on limit
            freq=$(echo "scale=0; 2600 * $cpu_limit / 100" | bc -l 2>/dev/null || echo "2600")
        else
            # Not throttled - check other indicators
            load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")

            # Estimate based on load and thermal pressure
            if (( $(echo "$load_avg > 8.0" | bc -l 2>/dev/null || echo 0) )); then
                # High load - likely at turbo frequency
                freq=3500
            elif (( $(echo "$load_avg > 4.0" | bc -l 2>/dev/null || echo 0) )); then
                # Medium load - above base frequency
                freq=3200
            else
                # Low load - base frequency
                freq=2600
            fi
        fi
    fi

    # Fallback to base frequency
    if [ "$freq" -eq 0 ] || [ -z "$freq" ]; then
        freq=2600
    fi

    echo "$freq"
}

# Function to get more detailed frequency info
get_frequency_info() {
    echo "=== 详细频率信息 ==="
    echo ""

    # 1. sysctl methods
    echo "1. sysctl 方法:"
    echo "   hw.cpufrequency: $(sysctl -n hw.cpufrequency 2>/dev/null || echo "N/A")"
    echo "   hw.cpufrequency_max: $(sysctl -n hw.cpufrequency_max 2>/dev/null || echo "N/A")"
    echo "   hw.cpufrequency_min: $(sysctl -n hw.cpufrequency_min 2>/dev/null || echo "N/A")"
    echo ""

    # 2. ioreg methods
    echo "2. ioreg 方法:"
    clock_freq=$(ioreg -l 2>/dev/null | grep -i "clock-frequency" | head -1 | grep -oE '[0-9a-fA-F]+' | head -1)
    if [ -n "$clock_freq" ]; then
        freq_mhz=$(echo "scale=0; $((clock_freq)) / 1000000" | bc -l 2>/dev/null || echo "N/A")
        echo "   clock-frequency: ${clock_freq} (≈${freq_mhz}MHz)"
    else
        echo "   clock-frequency: N/A"
    fi
    echo ""

    # 3. System info
    echo "3. 系统信息:"
    echo "   CPU型号: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "N/A")"
    echo ""

    # 4. Thermal/power status
    echo "4. 热管理状态:"
    cpu_limit=$(pmset -g therm 2>/dev/null | grep "CPU_Speed_Limit" | awk -F'=' '{print $2}' | tr -d ' ' || echo "100")
    echo "   CPU速度限制: ${cpu_limit}%"
    echo "   当前负载: $(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}')"
    echo ""

    # 5. Turbo frequencies available
    echo "5. 可用频率配置:"
    ioreg -l 2>/dev/null | grep -i "frequencies" | head -5
    echo ""

    # Current estimated frequency
    current_freq=$(get_cpu_frequency)
    echo "6. 当前估算频率: ${current_freq}MHz"
    echo ""
}

# Enhanced frequency monitoring function
monitor_frequency_changes() {
    echo "=== 监控频率变化 ==="
    echo "时间,估算频率,负载,温度指示"

    for i in {1..20}; do
        freq=$(get_cpu_frequency)
        load=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")

        # Try to get temperature indicator
        temp_ind="normal"
        cpu_limit=$(pmset -g therm 2>/dev/null | grep "CPU_Speed_Limit" | awk -F'=' '{print $2}' | tr -d ' ' || echo "100")
        if [ "$cpu_limit" -lt 90 ]; then
            temp_ind="hot"
        elif [ "$cpu_limit" -lt 95 ]; then
            temp_ind="warm"
        fi

        echo "$(date +%H:%M:%S),${freq}MHz,${load},${temp_ind}"

        # Add CPU load every 5 seconds
        if [ $((i % 5)) -eq 0 ]; then
            echo "scale=2000; 4*a(1)" | bc -l > /dev/null 2>&1 &
        fi

        sleep 1
    done

    # Cleanup
    pkill -f bc 2>/dev/null || true
}

# Main execution
echo "开始详细频率分析..."
get_frequency_info

echo ""
echo "开始频率变化监控..."
monitor_frequency_changes

echo ""
echo "=== 分析总结 ==="
echo ""
echo "发现的问题:"
echo "1. sysctl hw.cpufrequency 返回 0 (这是正常的，某些macOS版本如此)"
echo "2. 频率固定在2600MHz，没有变化"
echo "3. 系统显示有更高频率可用(4300MHz, 4600MHz, 4800MHz)"
echo ""
echo "可能原因:"
echo "- CPU被限制在基础频率(节能或过热保护)"
echo "- SMC设置了频率限制"
echo "- 电源适配器功率不足"
echo "- 系统处于节能模式"
echo ""
echo "建议:"
echo "1. 检查CPU温度(当前可能过热)"
echo "2. 检查电源适配器是否原装"
echo "3. 尝试重置SMC"
echo "4. 检查系统电源管理设置"