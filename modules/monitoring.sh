#!/bin/bash

# ==============================================================================
# 监控模块 - 电压、温度、频率、磁盘IO等监控功能
# ==============================================================================

# Source monitoring modules if available
MODULES_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [[ -f "$MODULES_DIR/monitoring_python.sh" ]]; then
    source "$MODULES_DIR/monitoring_python.sh"
fi
if [[ -f "$MODULES_DIR/powermetrics_python.sh" ]]; then
    source "$MODULES_DIR/powermetrics_python.sh"
fi
if [[ -f "$MODULES_DIR/continuous_powermetrics.sh" ]]; then
    source "$MODULES_DIR/continuous_powermetrics.sh"
fi
if [[ -f "$MODULES_DIR/continuous_monitoring.sh" ]]; then
    source "$MODULES_DIR/continuous_monitoring.sh"
fi

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

# New comprehensive sensor and power data acquisition function using powermetrics
# This function continuously reads from powermetrics with optimized samplers
get_sensor_data_powermetrics() {
    local cpu_temp_var="$1"
    local gpu_temp_var="$2"
    local fan_rpm_var="$3"
    local cpu_freq_var="$4"
    local c_plimit_var="$5"
    local c_prochot_var="$6"
    local c_thermlvl_var="$7"

    # Initialize return values
    eval "$cpu_temp_var='0'"
    eval "$gpu_temp_var='0'"
    eval "$fan_rpm_var='0'"
    eval "$cpu_freq_var='0'"
    eval "$c_plimit_var='0.00'"
    eval "$c_prochot_var='0'"
    eval "$c_thermlvl_var='0'"

    # Use temporary file for powermetrics output
    local PM_TMP_FILE="/tmp/pm_smc_out_$$"
    local pm_out=""
    local success=0

    # Try multiple approaches to get SMC data
    # Approach 1: Use smc,cpu_power,gpu_power samplers
    {
        powermetrics -n 1 -i 300 --samplers smc,cpu_power,gpu_power 2>/dev/null > "$PM_TMP_FILE"
    } &
    local PM_PID=$!

    # Wait for completion with shorter timeout for continuous operation
    local sleep_count=0
    while kill -0 $PM_PID 2>/dev/null && [ $sleep_count -lt 4 ]; do
        sleep 1
        sleep_count=$((sleep_count + 1))
    done

    if [ $sleep_count -lt 4 ]; then
        # Process completed successfully
        wait $PM_PID 2>/dev/null
        pm_out=$(cat "$PM_TMP_FILE" 2>/dev/null)
        if [ -n "$pm_out" ]; then
            success=1
        fi
    else
        # Timeout - kill the process
        kill -9 $PM_PID 2>/dev/null || true
    fi

    # Approach 2: If first approach failed or didn't return SMC data, try just smc
    if [ $success -eq 0 ] || ! echo "$pm_out" | grep -q "SMC sensors"; then
        {
            powermetrics -n 1 -i 300 --samplers smc 2>/dev/null > "$PM_TMP_FILE"
        } &
        local PM_PID2=$!

        local sleep_count2=0
        while kill -0 $PM_PID2 2>/dev/null && [ $sleep_count2 -lt 4 ]; do
            sleep 1
            sleep_count2=$((sleep_count2 + 1))
        done

        if [ $sleep_count2 -lt 4 ]; then
            wait $PM_PID2 2>/dev/null
            local pm_out2=$(cat "$PM_TMP_FILE" 2>/dev/null)
            if [ -n "$pm_out2" ]; then
                pm_out="$pm_out2"
                success=1
            fi
        else
            kill -9 $PM_PID2 2>/dev/null || true
        fi
    fi

    rm -f "$PM_TMP_FILE"

    # Parse SMC sensor data from powermetrics output
    if [ $success -eq 1 ] && [ -n "$pm_out" ]; then
        # Debug: log the raw output for troubleshooting
        # echo "[DEBUG] Powermetrics output: $pm_out" >&2

        # Extract CPU die temperature - multiple pattern attempts
        local cpu_temp=""
        # Try direct pattern first
        cpu_temp=$(echo "$pm_out" | awk '/CPU die temperature:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+$/) {
                    print int($i);
                    exit;
                }
            }
        }')

        # If that fails, try extracting any number after "CPU die temperature"
        if [ -z "$cpu_temp" ] || [ "$cpu_temp" = "0" ]; then
            cpu_temp=$(echo "$pm_out" | sed -n 's/.*CPU die temperature:[^0-9]*\([0-9.]*\).*/\1/p' | head -1 | cut -d. -f1)
        fi

        if [ -n "$cpu_temp" ] && echo "$cpu_temp" | grep -qE '^[0-9]+$' && [ "$cpu_temp" -ge 0 ] && [ "$cpu_temp" -le 120 ]; then
            eval "$cpu_temp_var='$cpu_temp'"
        else
            eval "$cpu_temp_var='0'"
        fi

        # Extract GPU die temperature
        local gpu_temp=""
        gpu_temp=$(echo "$pm_out" | awk '/GPU die temperature:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+$/) {
                    print int($i);
                    exit;
                }
            }
        }')

        if [ -z "$gpu_temp" ] || [ "$gpu_temp" = "0" ]; then
            gpu_temp=$(echo "$pm_out" | sed -n 's/.*GPU die temperature:[^0-9]*\([0-9.]*\).*/\1/p' | head -1 | cut -d. -f1)
        fi

        if [ -n "$gpu_temp" ] && echo "$gpu_temp" | grep -qE '^[0-9]+$' && [ "$gpu_temp" -ge 0 ] && [ "$gpu_temp" -le 120 ]; then
            eval "$gpu_temp_var='$gpu_temp'"
        else
            eval "$gpu_temp_var='0'"
        fi

        # Extract fan RPM - handle "Fan: XXXX.XX rpm" format
        local fan_rpm=""
        fan_rpm=$(echo "$pm_out" | awk '/Fan:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+$/) {
                    print int($i);
                    exit;
                }
            }
        }')

        if [ -z "$fan_rpm" ] || [ "$fan_rpm" = "0" ]; then
            fan_rpm=$(echo "$pm_out" | sed -n 's/.*Fan:[^0-9]*\([0-9.]*\).*/\1/p' | head -1 | cut -d. -f1)
        fi

        if [ -n "$fan_rpm" ] && [ "$fan_rpm" -ge 0 ] && [ "$fan_rpm" -le 10000 ]; then
            eval "$fan_rpm_var='$fan_rpm'"
        else
            eval "$fan_rpm_var='0'"
        fi

        # Extract CPU Plimit
        local c_pl=""
        c_pl=$(echo "$pm_out" | awk '/CPU Plimit:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+$/) {
                    print $i;
                    exit;
                }
            }
        }')

        if [ -z "$c_pl" ]; then
            c_pl=$(echo "$pm_out" | sed -n 's/.*CPU Plimit:[^0-9.]*\([0-9.]*\).*/\1/p' | head -1)
        fi

        if [ -n "$c_pl" ] && echo "$c_pl" | grep -qE '^[0-9.]+$'; then
            eval "$c_plimit_var='$c_pl'"
        else
            eval "$c_plimit_var='0.00'"
        fi

        # Extract prochots count
        local c_pr=""
        c_pr=$(echo "$pm_out" | awk '/Number of prochots:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9]+$/) {
                    print $i;
                    exit;
                }
            }
        }')

        if [ -z "$c_pr" ]; then
            c_pr=$(echo "$pm_out" | sed -n 's/.*Number of prochots:[^0-9]*\([0-9]*\).*/\1/p' | head -1)
        fi

        if [ -n "$c_pr" ] && echo "$c_pr" | grep -qE '^[0-9]+$'; then
            eval "$c_prochot_var='$c_pr'"
        else
            eval "$c_prochot_var='0'"
        fi

        # Extract thermal level
        local c_tl=""
        c_tl=$(echo "$pm_out" | awk '/CPU Thermal level:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9]+$/) {
                    print $i;
                    exit;
                }
            }
        }')

        if [ -z "$c_tl" ]; then
            c_tl=$(echo "$pm_out" | sed -n 's/.*CPU Thermal level:[^0-9]*\([0-9]*\).*/\1/p' | head -1)
        fi

        if [ -n "$c_tl" ] && echo "$c_tl" | grep -qE '^[0-9]+$'; then
            eval "$c_thermlvl_var='$c_tl'"
        else
            eval "$c_thermlvl_var='0'"
        fi

        # Extract CPU frequency if available in output
        local c_freq=""
        c_freq=$(echo "$pm_out" | awk '/CPU [0-9]* average frequency/ {sum+=$5; count++} END {if(count>0) print int(sum/count)}')
        if [ -z "$c_freq" ] || ! echo "$c_freq" | grep -qE '^[0-9]+$' || [ "$c_freq" -eq 0 ]; then
            # Try alternative pattern for Apple Silicon
            c_freq=$(echo "$pm_out" | awk '/E cluster.*frequency/ {print $4; exit}' | sed 's/MHz//')
        fi
        # Validate frequency range
        if [ -n "$c_freq" ] && echo "$c_freq" | grep -qE '^[0-9]+$' && [ "$c_freq" -ge 400 ] && [ "$c_freq" -le 6000 ]; then
            eval "$cpu_freq_var='$c_freq'"
        else
            # Last resort: sysctl
            local cpu_freq_sysctl=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
            if [ "$cpu_freq_sysctl" -ge 400 ] && [ "$cpu_freq_sysctl" -le 6000 ]; then
                eval "$cpu_freq_var='$cpu_freq_sysctl'"
            else
                eval "$cpu_freq_var='800'"
            fi
        fi

        return 0
    fi

    return 1
}

# Power data acquisition function using powermetrics
# This function extracts CPU and GPU power data
get_power_data_powermetrics() {
    local cpu_power_var="$1"
    local gpu_power_var="$2"
    local mem_power_var="$3"

    # Initialize return values
    eval "$cpu_power_var='N/A'"
    eval "$gpu_power_var='N/A'"
    eval "$mem_power_var='N/A'"

    # Use temporary file for powermetrics output
    local PM_POWER_TMP="/tmp/pm_power_out_$$"
    local pm_power_out=""
    local success=0

    # Run powermetrics with power samplers
    {
        powermetrics -n 1 -i 300 --samplers cpu_power,gpu_power 2>/dev/null > "$PM_POWER_TMP"
    } &
    local PM_POWER_PID=$!

    # Wait for completion with timeout
    local sleep_count=0
    while kill -0 $PM_POWER_PID 2>/dev/null && [ $sleep_count -lt 4 ]; do
        sleep 1
        sleep_count=$((sleep_count + 1))
    done

    if [ $sleep_count -lt 4 ]; then
        # Process completed successfully
        wait $PM_POWER_PID 2>/dev/null
        pm_power_out=$(cat "$PM_POWER_TMP" 2>/dev/null)
        if [ -n "$pm_power_out" ]; then
            success=1
        fi
    else
        # Timeout - kill the process
        kill -9 $PM_POWER_PID 2>/dev/null || true
    fi
    rm -f "$PM_POWER_TMP"

    # Parse power data from powermetrics output
    if [ $success -eq 1 ] && [ -n "$pm_power_out" ]; then
        # CPU package power - more robust extraction
        local cpu_pkg_power=$(echo "$pm_power_out" | awk '
        /CPU Power:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+W$/) {
                    gsub(/W/, "", $i);
                    print $i;
                    exit;
                }
            }
        }
        /Package Power:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+W$/) {
                    gsub(/W/, "", $i);
                    print $i;
                    exit;
                }
            }
        }
        /CPU package power:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+W$/) {
                    gsub(/W/, "", $i);
                    print $i;
                    exit;
                }
            }
        }' | head -1)

        # GPU package power
        local gpu_pkg_power=$(echo "$pm_power_out" | awk '
        /GPU Power:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+W$/) {
                    gsub(/W/, "", $i);
                    print $i;
                    exit;
                }
            }
        }
        /GPU package power:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+W$/) {
                    gsub(/W/, "", $i);
                    print $i;
                    exit;
                }
            }
        }' | head -1)

        # Memory power
        local mem_power=$(echo "$pm_power_out" | awk '
        /Memory Power:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+W$/) {
                    gsub(/W/, "", $i);
                    print $i;
                    exit;
                }
            }
        }
        /DRAM Power:/ {
            for(i=1; i<=NF; i++) {
                if($i ~ /^[0-9.]+W$/) {
                    gsub(/W/, "", $i);
                    print $i;
                    exit;
                }
            }
        }' | head -1)

        # Validate and assign values
        if [ -n "$cpu_pkg_power" ] && echo "$cpu_pkg_power" | grep -qE '^[0-9.]+$'; then
            # Cap at 150W for Intel mobile CPUs
            if (( $(echo "$cpu_pkg_power > 150" | bc -l 2>/dev/null || echo 0) )); then
                cpu_pkg_power="150.0"
            fi
            eval "$cpu_power_var='$cpu_pkg_power'"
        fi

        if [ -n "$gpu_pkg_power" ] && echo "$gpu_pkg_power" | grep -qE '^[0-9.]+$'; then
            # Cap at 100W for mobile GPUs
            if (( $(echo "$gpu_pkg_power > 100" | bc -l 2>/dev/null || echo 0) )); then
                gpu_pkg_power="100.0"
            fi
            eval "$gpu_power_var='$gpu_pkg_power'"
        fi

        if [ -n "$mem_power" ] && echo "$mem_power" | grep -qE '^[0-9.]+$'; then
            # Cap at 25W for memory
            if (( $(echo "$mem_power > 25" | bc -l 2>/dev/null || echo 0) )); then
                mem_power="25.0"
            fi
            eval "$mem_power_var='$mem_power'"
        fi

        return 0
    fi

    return 1
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

# Wrapper function to start power monitoring with mode selection
start_power_monitor() {
    if [[ "$PYTHON_MONITOR" == "true" ]] && check_python_monitor_available; then
        log "${GREEN}[监控] 使用Python功率监控模式${NC}"
        if start_power_monitor_python "$@"; then
            return 0
        else
            log "${YELLOW}[监控] Python功率监控启动失败，回退到Shell监控${NC}"
            PYTHON_MONITOR=false
        fi
    fi

    # Fall back to shell monitoring
    start_power_monitor_shell "$@"
}

# Power consumption monitor (Shell version)
start_power_monitor_shell() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            if [ "$EUID" -eq 0 ]; then
                # Use powermetrics for comprehensive power monitoring
                cpu_pkg_power="N/A"
                gpu_pkg_power="N/A"
                mem_power="N/A"

                # Use new power data acquisition function
                if get_power_data_powermetrics cpu_pkg_power gpu_pkg_power mem_power; then
                    log "${GREEN}[监控] 功率数据采集成功 (powermetrics)${NC}" >&2
                else
                    log "${YELLOW}[监控] 功率数据采集失败${NC}" >&2
                fi
            else
                # Non-root fallback - use ioreg for basic power estimation
                # This is less accurate but doesn't require sudo
                cpu_pkg_power="N/A"
                gpu_pkg_power="N/A"
                mem_power="N/A"
            fi

            # Log power data
            echo "$ts,$cpu_pkg_power,$gpu_pkg_power,$mem_power" >> "$POWER_LOG"

            # Display power info in log
            if [ "$cpu_pkg_power" != "N/A" ]; then
                log "${GREEN}[监控] 估算功耗 - CPU: ${cpu_pkg_power}W, GPU: ${gpu_pkg_power}W${NC}" >&2
            fi

            sleep $SAMPLE_INTERVAL
        done
    ) & POWER_PID=$!
    log "${GREEN}[监控] 功耗记录已启动${NC}"
}

# Wrapper function to start thermal monitoring with mode selection
start_thermal_monitor() {
    if [[ "$PYTHON_MONITOR" == "true" ]] && check_python_monitor_available; then
        log "${GREEN}[监控] 使用Python监控模式${NC}"
        if start_thermal_monitor_python "$@"; then
            return 0
        else
            log "${YELLOW}[监控] Python监控启动失败，回退到Shell监控${NC}"
            PYTHON_MONITOR=false
        fi
    fi

    # Fall back to shell monitoring
    start_thermal_monitor_shell "$@"
}

# Combined Thermal & Throttling monitor (Shell version)
start_thermal_monitor_shell() {
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
                # Use new simplified powermetrics sensor data acquisition
                if get_sensor_data_powermetrics cpu_temp gpu_temp fan_rpm cpu_freq c_plimit c_prochot c_thermlvl; then
                    log "${GREEN}[监控] SMC传感器数据采集成功 (powermetrics)${NC}" >&2
                    # Debug output
                    # log "[DEBUG] CPU Temp: $cpu_temp, GPU Temp: $gpu_temp, Fan: $fan_rpm" >&2
                else
                    log "${YELLOW}[监控] SMC传感器数据采集失败，使用回退方法${NC}" >&2
                fi

                # Fallback: Get SMC data directly from ioreg (more reliable during stress)
                if [ "$cpu_temp" = "0" ] || [ -z "$cpu_temp" ] || [ "$cpu_temp" = "N/A" ]; then
                    # Try multiple ioreg approaches for CPU temperature
                    cpu_temp=$(ioreg -l 2>/dev/null | grep -i '"Temperature"' | grep -oE '[0-9]+' | head -1)
                    if [ -z "$cpu_temp" ] || [ "$cpu_temp" = "0" ]; then
                        cpu_temp=$(ioreg -l 2>/dev/null | grep -i "TC0P" | grep -oE '[0-9]+' | head -1)
                    fi
                    if [ -z "$cpu_temp" ] || [ "$cpu_temp" = "0" ]; then
                        cpu_temp=$(ioreg -l 2>/dev/null | grep -i "TC0D" | grep -oE '[0-9]+' | head -1)
                    fi
                    if [ -z "$cpu_temp" ] || [ "$cpu_temp" = "0" ]; then
                        cpu_temp=$(ioreg -l 2>/dev/null | grep -i "TCSA" | grep -oE '[0-9]+' | head -1)
                    fi
                fi
                if [ "$fan_rpm" = "0" ] || [ -z "$fan_rpm" ] || [ "$fan_rpm" = "N/A" ]; then
                    # Try multiple ioreg approaches for fan speed
                    fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan"' | grep -oE '[0-9]+' | head -1)
                    if [ -z "$fan_rpm" ] || [ "$fan_rpm" = "0" ]; then
                        fan_rpm=$(ioreg -l 2>/dev/null | grep -i "F0Ac" | grep -oE '[0-9]+' | head -1)
                    fi
                    if [ -z "$fan_rpm" ] || [ "$fan_rpm" = "0" ]; then
                        fan_rpm=$(ioreg -l 2>/dev/null | grep -i "F0Tg" | grep -oE '[0-9]+' | head -1)
                    fi
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