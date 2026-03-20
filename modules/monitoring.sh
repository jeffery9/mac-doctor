#!/bin/bash

# ==============================================================================
# 监控模块 - 电压、温度、频率、磁盘IO等监控功能
# ==============================================================================

# Check powermetrics availability and capabilities
check_powermetrics() {
    if ! command -v powermetrics >/dev/null 2>&1; then
        log "${YELLOW}[监控] powermetrics 不可用，将使用简化监控模式${NC}"
        return 1
    fi

    # Test powermetrics basic functionality
    test_output=$(powermetrics -n 1 -i 500 --samplers cpu 2>/dev/null | head -5)
    if [ -z "$test_output" ]; then
        log "${YELLOW}[监控] powermetrics 测试失败，可能权限不足${NC}"
        return 1
    fi

    log "${GREEN}[监控] powermetrics 可用，将启用高级监控模式${NC}"
    return 0
}

# Initialize CSV logs
initialize_csv_logs() {
    echo "Timestamp,Voltage_mV,Current_mA" > "$VOLTAGE_LOG"
    echo "Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Activity_%,CPU_Freq_MHz,Kernel_Task_%,CPU_Speed_Limit_%,CPU_Plimit,Prochots,Thermal_Level" > "$THERMAL_LOG"
    echo "Timestamp,CPU_Package_W,GPU_Package_W,Memory_W" > "$POWER_LOG"
    echo "Timestamp,KB_t,TPS,MB_s" > "$DISK_LOG"
    > "$KERNEL_LOG"
}

# Voltage & Current monitor
start_voltage_monitor() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)
            vol=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"Voltage"' | grep -v 'Adapter' | grep -v 'Legacy' | head -1 | awk '{print $NF}' | tr -d ',')
            cur=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"Current"' | grep -v 'Adapter' | head -1 | awk '{print $NF}' | tr -d ',')
            if [ -n "$vol" ] && [ "$vol" -gt 8000 ] 2>/dev/null && [ "$vol" -lt 18000 ] 2>/dev/null; then
                echo "$ts,$vol,$cur" >> "$VOLTAGE_LOG"
            fi
            sleep $SAMPLE_INTERVAL
        done
    ) & VOL_PID=$!
    log "${GREEN}[监控] 电压记录已启动${NC}"
}

# Combined Thermal & Throttling monitor
start_thermal_monitor() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            # Multi-method GPU temperature reading
            gpu_temp="0"
            gpu_act="0"

            # Method 1: ioreg PerformanceStatistics
            gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "temperature" | head -1)
            if [ -n "$gpu_line" ]; then
                gpu_temp=$(echo "$gpu_line" | grep -o 'Temperature(C)=[0-9]*' | grep -oE '[0-9]+' || echo "0")
                gpu_act=$(echo "$gpu_line" | grep -o 'GPU Activity(%)=[0-9]*' | grep -oE '[0-9]+' || echo "0")
            fi

            # Method 2: SMC via ioreg (fallback)
            if [ "$gpu_temp" = "0" ]; then
                smc_gpu_temp=$(ioreg -l | grep -i "gpu-temp" | grep -oE '[0-9]+' | head -1)
                if [ -n "$smc_gpu_temp" ]; then
                    gpu_temp="$smc_gpu_temp"
                fi
            fi

            # Method 3: osx-cpu-temp if available (last resort)
            if [ "$gpu_temp" = "0" ] && command -v osx-cpu-temp >/dev/null 2>&1; then
                temp_output=$(osx-cpu-temp 2>/dev/null)
                if echo "$temp_output" | grep -q "GPU"; then
                    gpu_temp=$(echo "$temp_output" | grep "GPU" | grep -oE '[0-9]+' | head -1 || echo "0")
                fi
            fi

            [ -z "$gpu_temp" ] && gpu_temp="0"
            [ -z "$gpu_act" ] && gpu_act="0"

            cpu_freq="0"
            cpu_temp="0"
            fan_rpm="0"
            c_plimit="0.00"
            c_prochot="0"
            c_thermlvl="0"

            if [ "$EUID" -eq 0 ]; then
                # Enhanced powermetrics strategy for comprehensive monitoring
                # Use background process with controlled execution time
                PM_TMP_FILE="/tmp/pm_out_$$"

                # Run powermetrics with comprehensive samplers for Intel and Apple Silicon
                # Include: cpu, gpu, thermal, smc, power, memory, disk for complete monitoring
                # -n 1 -i 1000: single sample with 1s interval for stable readings
                # Use background execution with sleep to prevent hanging
                # Optimized sampler selection for high-load scenarios
                {
                    powermetrics -n 1 -i 500 --samplers smc,cpu_power,gpu_power,thermal 2>/dev/null > "$PM_TMP_FILE"
                } &
                PM_PID=$!

                # Wait for completion with a manual timeout using sleep
                sleep_count=0
                while kill -0 $PM_PID 2>/dev/null && [ $sleep_count -lt 8 ]; do
                    sleep 1
                    sleep_count=$((sleep_count + 1))
                done

                if [ $sleep_count -lt 8 ]; then
                    # Process completed successfully
                    wait $PM_PID 2>/dev/null
                    pm_out=$(cat "$PM_TMP_FILE" 2>/dev/null)
                    if [ -n "$pm_out" ]; then
                        log "${GREEN}[监控] powermetrics 数据采集成功${NC}" >&2
                    else
                        log "${YELLOW}[监控] powermetrics 返回空数据${NC}" >&2
                    fi
                else
                    # Timeout - kill the process
                    kill -9 $PM_PID 2>/dev/null || true
                    pm_out=""
                    log "${YELLOW}[监控] powermetrics 超时，使用回退方法${NC}" >&2
                fi
                rm -f "$PM_TMP_FILE"

                # Enhanced parsing with comprehensive pattern matching for all samplers
                if [ -n "$pm_out" ]; then
                    # CPU temperature - multiple patterns for different macOS versions and chip types
                    c_tmp=$(echo "$pm_out" | awk '/CPU die temperature/ {print $4; exit}' | cut -d. -f1)
                    if [ -z "$c_tmp" ] || ! echo "$c_tmp" | grep -qE '^[0-9]+$'; then
                        c_tmp=$(echo "$pm_out" | awk '/CPU Temperature:/ {print $3; exit}' | cut -d. -f1)
                    fi
                    if [ -z "$c_tmp" ] || ! echo "$c_tmp" | grep -qE '^[0-9]+$'; then
                        # Apple Silicon pattern
                        c_tmp=$(echo "$pm_out" | awk '/CPU die temperature:/ {print $4; exit}' | cut -d. -f1)
                    fi
                    if [ -n "$c_tmp" ] && echo "$c_tmp" | grep -qE '^[0-9]+$' && [ "$c_tmp" -ge 0 ] && [ "$c_tmp" -le 120 ]; then
                        cpu_temp="$c_tmp"
                    fi

                    # Fan RPM - try multiple sources
                    fan_rpm=$(echo "$pm_out" | awk '/Fan.*RPM/ {print $2; exit}' | head -1)
                    if [ -z "$fan_rpm" ] || ! echo "$fan_rpm" | grep -qE '^[0-9]+$'; then
                        fan_rpm=$(echo "$pm_out" | awk '/Fan.*speed/ {print $3; exit}' | head -1)
                    fi
                    if [ -z "$fan_rpm" ] || ! echo "$fan_rpm" | grep -qE '^[0-9]+$'; then
                        # Fallback to ioreg if powermetrics doesn't have fan data
                        fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan"' | grep -oE '[0-9]+' | head -1)
                    fi

                    # Enhanced frequency parsing with comprehensive patterns
                    c_freq=""
                    # Method 1: Average frequency across all cores (Intel)
                    c_freq=$(echo "$pm_out" | awk '/CPU [0-9]* average frequency/ {sum+=$5; count++} END {if(count>0) print int(sum/count)}')
                    if [ -z "$c_freq" ] || ! echo "$c_freq" | grep -qE '^[0-9]+$' || [ "$c_freq" -eq 0 ]; then
                        # Method 2: Overall CPU average frequency
                        c_freq=$(echo "$pm_out" | awk '/CPU average frequency/ {gsub(/MHz/, "", $4); print $4; exit}')
                    fi
                    if [ -z "$c_freq" ] || ! echo "$c_freq" | grep -qE '^[0-9]+$' || [ "$c_freq" -eq 0 ]; then
                        # Method 3: Individual core frequencies
                        c_freq=$(echo "$pm_out" | awk '/CPU[0-9]+:/ && /frequency/ {gsub(/MHz/, "", $NF); if($NF ~ /^[0-9]+$/) sum+=$NF; count++} END {if(count>0) print int(sum/count)}')
                    fi
                    if [ -z "$c_freq" ] || ! echo "$c_freq" | grep -qE '^[0-9]+$' || [ "$c_freq" -eq 0 ]; then
                        # Method 4: Apple Silicon pattern
                        c_freq=$(echo "$pm_out" | awk '/E cluster.*frequency/ {print $4; exit}' | sed 's/MHz//')
                    fi
                    # Validate frequency range
                    if [ -n "$c_freq" ] && echo "$c_freq" | grep -qE '^[0-9]+$' && [ "$c_freq" -ge 400 ] && [ "$c_freq" -le 6000 ]; then
                        cpu_freq="$c_freq"
                    else
                        # Last resort: sysctl
                        cpu_freq_sysctl=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
                        if [ "$cpu_freq_sysctl" -ge 400 ] && [ "$cpu_freq_sysctl" -le 6000 ]; then
                            cpu_freq="$cpu_freq_sysctl"
                        else
                            cpu_freq="800"
                        fi
                    fi

                    # Enhanced Plimit parsing
                    c_pl=$(echo "$pm_out" | awk '/CPU Plimit:/ {gsub(/%/, "", $3); print $3; exit}')
                    if [ -z "$c_pl" ] || ! echo "$c_pl" | grep -qE '^[0-9.]+$'; then
                        # Try alternative pattern
                        c_pl=$(echo "$pm_out" | awk '/Power limit/ {print $3; exit}' | sed 's/%//')
                    fi
                    if [ -n "$c_pl" ] && echo "$c_pl" | grep -qE '^[0-9.]+$'; then
                        c_plimit="$c_pl"
                    fi

                    # Prochot parsing
                    c_pr=$(echo "$pm_out" | awk '/Number of prochots:/ {print $4; exit}')
                    if [ -n "$c_pr" ] && echo "$c_pr" | grep -qE '^[0-9]+$'; then
                        c_prochot="$c_pr"
                    fi

                    # Thermal level parsing
                    c_tl=$(echo "$pm_out" | awk '/CPU Thermal level:/ {print $4; exit}')
                    if [ -z "$c_tl" ] || ! echo "$c_tl" | grep -qE '^[0-9]+$'; then
                        # Try alternative pattern
                        c_tl=$(echo "$pm_out" | awk '/Thermal level/ {print $3; exit}')
                    fi
                    if [ -n "$c_tl" ] && echo "$c_tl" | grep -qE '^[0-9]+$'; then
                        c_thermlvl="$c_tl"
                    fi
                else
                    # If powermetrics failed or returned empty, use fallback methods
                    log "${YELLOW}[监控] powermetrics 无响应，使用回退方法${NC}" >&2
                fi
                
                # Additional data from comprehensive powermetrics
                if [ -n "$pm_out" ]; then
                    # Memory thermal info (if available)
                    mem_thermal=$(echo "$pm_out" | awk '/Memory thermal level:/ {print $4; exit}')
                    if [ -n "$mem_thermal" ] && echo "$mem_thermal" | grep -qE '^[0-9]+$'; then
                        # Could log memory thermal level if needed
                        :
                    fi
                fi

                # Fallback: Get SMC data directly from ioreg (more reliable during stress)
                if [ "$cpu_temp" = "0" ] || [ -z "$cpu_temp" ]; then
                    cpu_temp=$(ioreg -l 2>/dev/null | grep -i '"Temperature"' | grep -oE '[0-9]+' | head -1)
                fi
                if [ "$fan_rpm" = "0" ] || [ -z "$fan_rpm" ]; then
                    fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan"' | grep -oE '[0-9]+' | head -1)
                fi
                # Validate fallback values
                if ! echo "$cpu_temp" | grep -qE '^[0-9]+$' || [ "$cpu_temp" -lt 0 ] || [ "$cpu_temp" -gt 120 ]; then cpu_temp="0"; fi
                if ! echo "$fan_rpm" | grep -qE '^[0-9]+$' || [ "$fan_rpm" -lt 0 ] || [ "$fan_rpm" -gt 10000 ]; then fan_rpm="0"; fi
                if ! echo "$cpu_freq" | grep -qE '^[0-9]+$' || [ "$cpu_freq" -lt 400 ] || [ "$cpu_freq" -gt 6000 ]; then cpu_freq="800"; fi
            else
                # Non-root fallback for basic info with validation
                cpu_temp=$(ioreg -l | grep -i "temperature" | grep -oE '[0-9]+' | head -1 || echo "0")
                fan_rpm=$(ioreg -l | grep -i "fan" | grep -oE '[0-9]+' | head -1 || echo "0")
                # Try basic frequency from sysctl as last resort
                cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")

                # Validate non-root values
                if ! echo "$cpu_temp" | grep -qE '^[0-9]+$' || [ "$cpu_temp" -lt 0 ] || [ "$cpu_temp" -gt 120 ]; then cpu_temp="0"; fi
                if ! echo "$fan_rpm" | grep -qE '^[0-9]+$' || [ "$fan_rpm" -lt 0 ] || [ "$fan_rpm" -gt 10000 ]; then fan_rpm="0"; fi
                if ! echo "$cpu_freq" | grep -qE '^[0-9]+$' || [ "$cpu_freq" -lt 400 ] || [ "$cpu_freq" -gt 6000 ]; then cpu_freq="800"; fi
            fi

            ktask=$(top -l 1 | awk '/kernel_task/ {print $3}' | head -1 | tr -d '%')
            [ -z "$ktask" ] && ktask="0.0"
            cpu_limit=$(pmset -g therm 2>/dev/null | grep "CPU_Speed_Limit" | awk -F'=' '{print $2}' | tr -d ' ' || echo "100")
            [ -z "$cpu_limit" ] && cpu_limit="100"

            echo "$ts,$cpu_temp,$gpu_temp,$fan_rpm,$gpu_act,$cpu_freq,$ktask,$cpu_limit,$c_plimit,$c_prochot,$c_thermlvl" >> "$THERMAL_LOG"
            sleep $SAMPLE_INTERVAL
        done
    ) & THERM_PID=$!
    log "${GREEN}[监控] 核心频率与热节流监控已启动${NC}"
}

# Enhanced Power monitor using powermetrics with high-load optimization
start_power_monitor() {
    (
        # High-load optimized power monitoring
        HIGH_LOAD_MODE=0
        RETRY_COUNT=0
        MAX_RETRIES=3

        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            if [ "$EUID" -eq 0 ]; then
                # Use powermetrics for comprehensive power monitoring
                PM_POWER_TMP="/tmp/pm_power_$$"
                cpu_pkg_power="N/A"
                gpu_pkg_power="N/A"
                mem_power="N/A"

                # Adjust timeout based on system load
                load_avg=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}' | sed 's/,//')
                if (( $(echo "$load_avg > 2.0" | bc -l 2>/dev/null || echo 0) )); then
                    HIGH_LOAD_MODE=1
                    timeout_val=10  # Longer timeout for high load
                    sample_duration=1000  # Shorter sample duration
                else
                    HIGH_LOAD_MODE=0
                    timeout_val=6
                    sample_duration=500
                fi

                # Retry mechanism for high-load scenarios
                for retry in $(seq 1 $MAX_RETRIES); do
                    # Run powermetrics for power data with comprehensive samplers
                    {
                        powermetrics -n 1 -i $sample_duration --samplers smc 2>/dev/null > "$PM_POWER_TMP"
                    } &
                    PM_POWER_PID=$!

                    # Wait for completion with dynamic timeout
                    sleep_count=0
                    while kill -0 $PM_POWER_PID 2>/dev/null && [ $sleep_count -lt $timeout_val ]; do
                        sleep 1
                        sleep_count=$((sleep_count + 1))
                    done

                    if [ $sleep_count -lt $timeout_val ]; then
                        # Process completed successfully
                        wait $PM_POWER_PID 2>/dev/null
                        pm_power_out=$(cat "$PM_POWER_TMP" 2>/dev/null)

                        if [ -n "$pm_power_out" ] && echo "$pm_power_out" | grep -q "Power"; then
                            log "${GREEN}[监控] powermetrics 功耗数据采集成功 (尝试 $retry)${NC}" >&2
                            RETRY_COUNT=0
                            break
                        else
                            log "${YELLOW}[监控] powermetrics 数据不完整，重试中 ($retry/$MAX_RETRIES)${NC}" >&2
                            RETRY_COUNT=$retry
                        fi
                    else
                        # Timeout - kill the process
                        kill -9 $PM_POWER_PID 2>/dev/null || true
                        log "${YELLOW}[监控] powermetrics 超时，重试中 ($retry/$MAX_RETRIES)${NC}" >&2
                        RETRY_COUNT=$retry
                    fi

                    # Brief pause between retries
                    if [ $retry -lt $MAX_RETRIES ]; then
                        sleep 2
                    fi
                done

                # Parse power data even if partial
                if [ -n "$pm_power_out" ]; then
                    # Parse CPU package power (multiple patterns)
                    cpu_pkg_power=$(echo "$pm_power_out" | grep -E "CPU.*Power|Package Power" | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /[0-9.]+W/) print $i}' | sed 's/W//' | head -1)
                    if [ -z "$cpu_pkg_power" ] || ! echo "$cpu_pkg_power" | grep -qE '^[0-9.]+$'; then
                        # Fallback: try extracting any power value
                        cpu_pkg_power=$(echo "$pm_power_out" | grep -oE '[0-9.]+W' | head -1 | sed 's/W//')
                    fi

                    # Parse GPU power
                    gpu_pkg_power=$(echo "$pm_power_out" | awk '/GPU Power/ {for(i=1;i<=NF;i++) if($i ~ /[0-9.]+W/) print $i; exit}' | sed 's/W//' | head -1)
                    if [ -z "$gpu_pkg_power" ] || ! echo "$gpu_pkg_power" | grep -qE '^[0-9.]+$'; then
                        # Try ioreg for GPU power as primary source (more reliable)
                        gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1)
                        gpu_pkg_power=$(echo "$gpu_line" | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+')
                    fi

                    # Parse Memory power
                    mem_power=$(echo "$pm_power_out" | awk '/Memory Power/ {for(i=1;i<=NF;i++) if($i ~ /[0-9.]+W/) print $i; exit}' | sed 's/W//' | head -1)
                    if [ -z "$mem_power" ] || ! echo "$mem_power" | grep -qE '^[0-9.]+$'; then
                        mem_power="N/A"
                    fi

                    # Validate parsed values
                    if [ -n "$cpu_pkg_power" ] && echo "$cpu_pkg_power" | grep -qE '^[0-9.]+$'; then
                        log "${GREEN}[监控] CPU功耗: ${cpu_pkg_power}W${NC}" >&2
                    else
                        cpu_pkg_power="N/A"
                    fi

                    if [ -n "$gpu_pkg_power" ] && echo "$gpu_pkg_power" | grep -qE '^[0-9.]+$'; then
                        log "${GREEN}[监控] GPU功耗: ${gpu_pkg_power}W${NC}" >&2
                    else
                        gpu_pkg_power="N/A"
                    fi
                else
                    log "${RED}[监控] 无法获取功耗数据${NC}" >&2
                fi
                rm -f "$PM_POWER_TMP"
            else
                # Non-root fallback: use ioreg for GPU power only
                gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1)
                gpu_pkg_power=$(echo "$gpu_line" | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "N/A")
                [ -z "$gpu_pkg_power" ] && gpu_pkg_power="N/A"
                cpu_pkg_power="N/A"
                mem_power="N/A"
            fi

            echo "$ts,$cpu_pkg_power,$gpu_pkg_power,$mem_power" >> "$POWER_LOG"
            sleep $SAMPLE_INTERVAL
        done
    ) & POWER_PID=$!
}

# Disk IO monitor
start_disk_io_monitor() {
    (
        root_disk=$(diskutil list | awk '/internal, physical/ {print $1; exit}' | grep -o "disk[0-9]*")
        if [ -z "$root_disk" ]; then root_disk="disk0"; fi
        iostat -d -w $SAMPLE_INTERVAL $root_disk 2>/dev/null | while read -r line; do
            if [ $EARLY_STOP -eq 1 ]; then break; fi
            if echo "$line" | grep -qE "[a-zA-Z]"; then continue; fi
            ts=$(date +%H:%M:%S)
            kb_t=$(echo "$line" | awk '{print $1}')
            tps=$(echo "$line" | awk '{print $2}')
            mb_s=$(echo "$line" | awk '{print $3}')
            echo "$ts,$kb_t,$tps,$mb_s" >> "$DISK_LOG"
        done
    ) & DISK_IO_PID=$!
    log "${GREEN}[监控] 硬盘 I/O 监控已启动${NC}"
}

# Kernel error monitor
start_kernel_monitor() {
    if [ "$EUID" -eq 0 ]; then
        (
            log stream --predicate 'eventMessage contains "droop" OR eventMessage contains "hang" OR eventMessage contains "overcurrent" OR eventMessage contains "thermal"' --style syslog 2>/dev/null | while IFS= read -r line; do
                echo "$(date +%H:%M:%S) $line" >> "$KERNEL_LOG"
            done
        ) & LOG_PID=$!
        log "${GREEN}[监控] 内核警告日志已启动${NC}"
    fi
}

# Stop all monitors
stop_all_monitors() {
    EARLY_STOP=1
    touch /tmp/stress_early_stop.flag
    wait $VOL_PID $THERM_PID $POWER_PID $DISK_IO_PID $LOG_PID 2>/dev/null
    rm -f /tmp/stress_early_stop.flag
}