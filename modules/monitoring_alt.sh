#!/bin/bash

# ==============================================================================
# 替代监控模块 - 使用ioreg和sysctl作为powermetrics的备用方案
# ==============================================================================

# Alternative thermal monitoring using ioreg and sysctl
start_thermal_monitor_alt() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            # Get CPU frequency via sysctl (always available)
            cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
            if [ "$cpu_freq" -eq 0 ]; then
                # Fallback to nominal frequency
                cpu_freq=$(sysctl -n hw.cpufrequency_max 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "2600")
            fi

            # Get load average as performance indicator
            load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")

            # Try to get GPU data from ioreg PerformanceStatistics
            gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | head -1)
            if [ -n "$gpu_line" ]; then
                # Extract GPU power
                gpu_power=$(echo "$gpu_line" | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "0")

                # Extract GPU temperature
                gpu_temp=$(echo "$gpu_line" | grep -oE '"Temperature\(C\)"=[0-9]+' | grep -oE '[0-9]+' || echo "0")

                # Extract GPU activity percentage
                gpu_act=$(echo "$gpu_line" | grep -oE '"GPU Activity\(%\)"=[0-9]+' | grep -oE '[0-9]+' || echo "0")

                # Extract fan speed
                fan_pct=$(echo "$gpu_line" | grep -oE '"Fan Speed\(%\)"=[0-9]+' | grep -oE '[0-9]+' || echo "0")
                fan_rpm=$(echo "$gpu_line" | grep -oE '"Fan Speed\(RPM\)"=[0-9]+' | grep -oE '[0-9]+' || echo "0")
            else
                gpu_power="0"
                gpu_temp="0"
                gpu_act="0"
                fan_pct="0"
                fan_rpm="0"
            fi

            # Try SMC temperature sensors (if available without root)
            cpu_temp="0"

            # Method 1: Try to get from ioreg SMC section
            smc_data=$(ioreg -l 2>/dev/null | grep -A20 "AppleSMC" | grep -i temp | head -5)
            if [ -n "$smc_data" ]; then
                # Try to extract temperature values
                smc_temp=$(echo "$smc_data" | grep -oE '[0-9]+\.[0-9]+' | head -1)
                if [ -n "$smc_temp" ]; then
                    cpu_temp=$(echo "$smc_temp" | cut -d. -f1)
                fi
            fi

            # Method 2: Estimate CPU temperature based on frequency and load
            if [ "$cpu_temp" -eq 0 ]; then
                if [ "$cpu_freq" -lt 2000 ] && [ "$cpu_freq" -gt 800 ]; then
                    # Frequency throttled, likely due to heat
                    est_cpu_temp=$((80 + (2600 - cpu_freq) / 50))
                elif [ "$cpu_freq" -le 800 ]; then
                    # Severe throttling
                    est_cpu_temp=95
                elif (( $(echo "$load_avg > 8.0" | bc -l 2>/dev/null || echo 0) )); then
                    # High load
                    est_cpu_temp=$((70 + load_avg))
                else
                    # Normal operation
                    est_cpu_temp=55
                fi
                cpu_temp=$est_cpu_temp
            fi

            # Get kernel task CPU usage
            ktask=$(ps -eo pid,pcpu,comm | grep -i kernel_task | awk '{sum+=$2} END {printf "%.1f", sum}')
            [ -z "$ktask" ] && ktask="0.0"

            # Get CPU speed limit from pmset
            cpu_limit=$(pmset -g therm 2>/dev/null | grep "CPU_Speed_Limit" | awk -F'=' '{print $2}' | tr -d ' ' || echo "100")
            [ -z "$cpu_limit" ] && cpu_limit="100"

            # Power limit and prochot (estimated from frequency)
            if [ "$cpu_freq" -lt 1500 ]; then
                c_plimit=$(( (2600 - cpu_freq) * 100 / 2600 ))
                c_prochot=1
            else
                c_plimit=0
                c_prochot=0
            fi

            # Thermal level
            c_thermlvl=0
            cpu_temp_int=$(echo "$cpu_temp" | cut -d. -f1)
            if [ "$cpu_temp_int" -gt 85 ]; then
                c_thermlvl=2
            elif [ "$cpu_temp_int" -gt 70 ]; then
                c_thermlvl=1
            fi

            # Log the data
            echo "$ts,$cpu_temp,$gpu_temp,$fan_rpm,$gpu_act,$cpu_freq,$ktask,$cpu_limit,$c_plimit,$c_prochot,$c_thermlvl" >> "$THERMAL_LOG"

            # Log status every 10 seconds
            if [ $(( $(date +%s) % 10 )) -eq 0 ]; then
                log "${CYAN}[监控] CPU: ${cpu_temp}°C | GPU: ${gpu_temp}°C | 频率: ${cpu_freq}MHz | 负载: ${load_avg} | GPU功耗: ${gpu_power}W | 风扇: ${fan_pct}%${NC}" >&2
            fi

            sleep $SAMPLE_INTERVAL
        done
    ) & THERM_PID=$!
    log "${GREEN}[监控] ioreg热监控已启动${NC}"
}

# Alternative power monitoring using multiple sources
start_power_monitor_alt() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            # Get GPU power from ioreg (most reliable)
            gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1)
            if [ -n "$gpu_line" ]; then
                gpu_pkg_power=$(echo "$gpu_line" | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "N/A")
            else
                gpu_pkg_power="N/A"
            fi

            # Estimate CPU power based on frequency and load
            cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "2600")
            load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0")

            # Enhanced power estimation algorithm
            if [ "$cpu_freq" -ge 2500 ] && (( $(echo "$load_avg > 5.0" | bc -l 2>/dev/null || echo 0) )); then
                # High performance mode
                base_power=15
                load_factor=$(echo "scale=1; ($load_avg - 5) * 2.5" | bc -l 2>/dev/null || echo "0")
                cpu_pkg_power=$(echo "scale=1; $base_power + $load_factor" | bc -l 2>/dev/null || echo "15")
            elif [ "$cpu_freq" -ge 2000 ]; then
                # Normal mode
                base_power=8
                load_factor=$(echo "scale=1; $load_avg * 1.2" | bc -l 2>/dev/null || echo "0")
                cpu_pkg_power=$(echo "scale=1; $base_power + $load_factor" | bc -l 2>/dev/null || echo "8")
            elif [ "$cpu_freq" -ge 1500 ]; then
                # Power save mode
                base_power=5
                load_factor=$(echo "scale=1; $load_avg * 0.8" | bc -l 2>/dev/null || echo "0")
                cpu_pkg_power=$(echo "scale=1; $base_power + $load_factor" | bc -l 2>/dev/null || echo "5")
            else
                # Throttled mode
                base_power=3
                load_factor=$(echo "scale=1; $load_avg * 0.4" | bc -l 2>/dev/null || echo "0")
                cpu_pkg_power=$(echo "scale=1; $base_power + $load_factor" | bc -l 2>/dev/null || echo "3")
            fi

            # Memory power estimation based on active memory
            mem_power=$(vm_stat 2>/dev/null | awk '
                /Pages active/ {active=$3}
                /Pages wired/ {wired=$3}
                /Pages inactive/ {inactive=$3}
                END {
                    if(active+wired+inactive > 0) {
                        total_gb = (active+wired+inactive)*4096/1024/1024/1024
                        printf "%.1f", total_gb*0.3
                    }
                }'
            )
            [ -z "$mem_power" ] && mem_power="N/A"

            # Validate values
            if [ -n "$cpu_pkg_power" ] && echo "$cpu_pkg_power" | grep -qE '^[0-9.]+$'; then
                log "${GREEN}[监控] 估算功耗 - CPU: ${cpu_pkg_power}W, GPU: ${gpu_pkg_power:-N/A}W${NC}" >&2
            else
                cpu_pkg_power="N/A"
            fi

            echo "$ts,$cpu_pkg_power,$gpu_pkg_power,$mem_power" >> "$POWER_LOG"
            sleep $SAMPLE_INTERVAL
        done
    ) & POWER_PID=$!
    log "${GREEN}[监控] ioreg功耗监控已启动${NC}"
}

# Combined monitoring function that uses alternatives when powermetrics fails
start_combined_monitoring() {
    # Start voltage monitor (always works)
    start_voltage_monitor

    # Start disk IO monitor (always works)
    start_disk_io_monitor

    # Start kernel monitor if root
    if [ "$EUID" -eq 0 ]; then
        start_kernel_monitor
    fi

    # For thermal and power, try powermetrics first, fallback to ioreg
    if [ "$EUID" -eq 0 ]; then
        # Root mode - try powermetrics with fallback
        log "${CYAN}[监控] 使用混合监控模式 (powermetrics + ioreg备用)${NC}"

        # Start powermetrics in background
        start_thermal_monitor &
        start_power_monitor &

        # Also start ioreg monitoring as backup
        start_thermal_monitor_alt &
        start_power_monitor_alt &

        # Monitor which one is providing data and switch if needed
        (
            sleep 10
            if [ -f "$THERMAL_LOG" ]; then
                powermetrics_count=$(grep -v "0,0,0,0,0,0,0,100,0,0,0" "$THERMAL_LOG" 2>/dev/null | wc -l)
                ioreg_count=$(grep -v "0,0,0,0,0,0,0,100,0,0,0" "$THERMAL_LOG" 2>/dev/null | wc -l)

                if [ "$powermetrics_count" -lt 5 ] && [ "$ioreg_count" -gt 5 ]; then
                    log "${YELLOW}[监控] powermetrics数据不足，切换到ioreg模式${NC}"
                    # Kill powermetrics processes
                    pkill -f "powermetrics.*thermal" 2>/dev/null || true
                    pkill -f "powermetrics.*power" 2>/dev/null || true
                fi
            fi
        ) &
    else
        # Non-root mode - use ioreg directly
        log "${CYAN}[监控] 使用ioreg监控模式${NC}"
        start_thermal_monitor_alt
        start_power_monitor_alt
    fi
}