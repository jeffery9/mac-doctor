#!/bin/bash

# ==============================================================================
# 非Root权限监控模块 - 优化非root用户的数据采集
# ==============================================================================

# Non-root optimized thermal monitoring
start_thermal_monitor_nonroot() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            # Get CPU frequency using sysctl (always available)
            cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
            if [ "$cpu_freq" -eq 0 ]; then
                # Fallback to nominal frequency
                cpu_freq=$(sysctl -n hw.cpufrequency_max 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "2600")
            fi

            # Get load average as performance indicator
            load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")

            # Try to get GPU power from ioreg (sometimes works without root)
            gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1)
            gpu_power=$(echo "$gpu_line" | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "0")

            # Get GPU temperature if available
            gpu_temp_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "temperature" | head -1)
            gpu_temp=$(echo "$gpu_temp_line" | grep -oE '"Temperature\(C\)"=[0-9]+' | grep -oE '[0-9]+' || echo "0")

            # Estimate CPU temperature based on frequency drop
            if [ "$cpu_freq" -lt 2000 ] && [ "$cpu_freq" -gt 800 ]; then
                # Frequency throttled, likely due to heat
                est_cpu_temp=$((80 + (2600 - cpu_freq) / 50))
            elif [ "$cpu_freq" -le 800 ]; then
                # Severe throttling
                est_cpu_temp=95
            else
                # Normal operation
                est_cpu_temp=65
            fi

            # Get fan speed from ioreg if available
            fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan Speed(RPM)"' | grep -oE '[0-9]+' | head -1 || echo "0")
            if [ "$fan_rpm" -eq 0 ]; then
                # Try fan percentage
                fan_pct=$(ioreg -l 2>/dev/null | grep -i '"Fan Speed(%)"' | grep -oE '[0-9]+' | head -1 || echo "0")
                # Convert percentage to RPM (estimate)
                if [ "$fan_pct" -gt 0 ]; then
                    fan_rpm=$((fan_pct * 60))
                fi
            fi

            # Get kernel task CPU usage
            ktask=$(ps -eo pid,pcpu,comm | grep -i kernel_task | awk '{sum+=$2} END {printf "%.1f", sum}')
            [ -z "$ktask" ] && ktask="0.0"

            # Get CPU speed limit from pmset
            cpu_limit=$(pmset -g therm 2>/dev/null | grep "CPU_Speed_Limit" | awk -F'=' '{print $2}' | tr -d ' ' || echo "100")
            [ -z "$cpu_limit" ] && cpu_limit="100"

            # Power limit and prochot (estimated)
            if [ "$cpu_freq" -lt 1500 ]; then
                c_plimit=$(( (2600 - cpu_freq) * 100 / 2600 ))
                c_prochot=1
            else
                c_plimit=0
                c_prochot=0
            fi

            # Thermal level (estimated)
            c_thermlvl=0
            if [ "$est_cpu_temp" -gt 85 ]; then
                c_thermlvl=2
            elif [ "$est_cpu_temp" -gt 70 ]; then
                c_thermlvl=1
            fi

            # Log the data
            echo "$ts,$est_cpu_temp,$gpu_temp,$fan_rpm,$gpu_power,$cpu_freq,$ktask,$cpu_limit,$c_plimit,$c_prochot,$c_thermlvl" >> "$THERMAL_LOG"

            # Log status
            if [ $(( $(date +%s) % 10 )) -eq 0 ]; then
                log "${CYAN}[监控] CPU: ${cpu_freq}MHz | 负载: ${load_avg} | GPU: ${gpu_power}W | 风扇: ${fan_rpm}RPM${NC}" >&2
            fi

            sleep $SAMPLE_INTERVAL
        done
    ) & THERM_PID=$!
    log "${GREEN}[监控] 非Root热监控已启动${NC}"
}

# Non-root power monitoring
start_power_monitor_nonroot() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            # Get GPU power from ioreg (most reliable for non-root)
            gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1)
            gpu_pkg_power=$(echo "$gpu_line" | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "N/A")

            # Estimate CPU power based on frequency and load
            cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "2600")
            load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")

            # Power estimation formula
            if [ "$cpu_freq" -ge 2500 ] && (( $(echo "$load_avg > 5.0" | bc -l 2>/dev/null || echo 0) )); then
                # High performance mode
                cpu_pkg_power=$(echo "scale=1; 15 + ($load_avg - 5) * 3" | bc -l 2>/dev/null || echo "15")
            elif [ "$cpu_freq" -ge 2000 ]; then
                # Normal mode
                cpu_pkg_power=$(echo "scale=1; 8 + $load_avg * 1.5" | bc -l 2>/dev/null || echo "8")
            elif [ "$cpu_freq" -ge 1500 ]; then
                # Power save mode
                cpu_pkg_power=$(echo "scale=1; 5 + $load_avg" | bc -l 2>/dev/null || echo "5")
            else
                # Throttled mode
                cpu_pkg_power=$(echo "scale=1; 3 + $load_avg * 0.5" | bc -l 2>/dev/null || echo "3")
            fi

            # Memory power estimation
            mem_power=$(vm_stat 2>/dev/null | awk '/Pages active/ {active=$3} /Pages wired/ {wired=$3} /Pages inactive/ {inactive=$3} END {total=(active+wired+inactive)*4096/1024/1024/1024; printf "%.1f", total*0.5}')
            [ -z "$mem_power" ] && mem_power="N/A"

            # Validate values
            if [ -n "$cpu_pkg_power" ] && echo "$cpu_pkg_power" | grep -qE '^[0-9.]+$'; then
                log "${GREEN}[监控] 估算CPU功耗: ${cpu_pkg_power}W${NC}" >&2
            else
                cpu_pkg_power="N/A"
            fi

            echo "$ts,$cpu_pkg_power,$gpu_pkg_power,$mem_power" >> "$POWER_LOG"
            sleep $SAMPLE_INTERVAL
        done
    ) & POWER_PID=$!
    log "${GREEN}[监控] 非Root功耗监控已启动${NC}"
}

# Enhanced monitoring function with automatic root detection
start_enhanced_monitoring() {
    if [ "$EUID" -eq 0 ]; then
        # Root mode - use full capabilities
        start_voltage_monitor
        start_thermal_monitor
        start_power_monitor
        start_disk_io_monitor
        start_kernel_monitor
    else
        # Non-root mode - use optimized functions
        log "${YELLOW}[监控] 非Root模式，使用优化监控${NC}"
        # Use voltage monitor (doesn't require root)
        start_voltage_monitor
        # Use non-root thermal monitor
        start_thermal_monitor_nonroot
        # Use non-root power monitor
        start_power_monitor_nonroot
        # Use disk monitor (doesn't require root)
        start_disk_io_monitor
        # Skip kernel monitor (requires root)
    fi
}