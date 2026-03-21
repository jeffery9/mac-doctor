#!/bin/bash

# ==============================================================================
# Continuous Monitoring Functions using persistent powermetrics
# ==============================================================================

# Global flag for continuous monitoring mode
CONTINUOUS_MONITORING=0

# Initialize continuous monitoring
init_continuous_monitoring() {
    if [ "$EUID" -eq 0 ] && [[ "$PYTHON_MONITOR" != "true" ]]; then
        # Start continuous powermetrics with all required samplers
        if start_continuous_powermetrics "smc,cpu_power,gpu_power" 300; then
            CONTINUOUS_MONITORING=1
            log "${GREEN}[监控] 连续监控模式已启用${NC}"
            return 0
        else
            log "${YELLOW}[监控] 连续监控模式启动失败，使用传统模式${NC}"
            CONTINUOUS_MONITORING=0
        fi
    else
        CONTINUOUS_MONITORING=0
    fi
    return 1
}

# Cleanup continuous monitoring
cleanup_continuous_monitoring() {
    if [ $CONTINUOUS_MONITORING -eq 1 ]; then
        cleanup_continuous_powermetrics
        CONTINUOUS_MONITORING=0
    fi
}

# Continuous thermal monitoring function
start_thermal_monitor_continuous() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            # Multi-method GPU temperature reading (unchanged)
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

            [ -z "$gpu_temp" ] && gpu_temp="0"
            [ -z "$gpu_act" ] && gpu_act="0"

            cpu_freq="0"
            cpu_temp="0"
            fan_rpm="0"
            c_plimit="0.00"
            c_prochot="0"
            c_thermlvl="0"

            if [ $CONTINUOUS_MONITORING -eq 1 ]; then
                # Use continuous powermetrics data
                if get_continuous_sensor_data cpu_temp gpu_temp fan_rpm cpu_freq c_plimit c_prochot c_thermlvl; then
                    log "${GREEN}[监控] 连续传感器数据采集成功${NC}" >&2
                else
                    log "${YELLOW}[监控] 连续传感器数据采集失败，使用回退方法${NC}" >&2
                    # Fallback to traditional methods
                    cpu_temp=$(ioreg -l 2>/dev/null | grep -i '"Temperature"' | grep -oE '[0-9]+' | head -1)
                    fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan"' | grep -oE '[0-9]+' | head -1)
                    cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
                fi
            else
                # Use traditional powermetrics or fallback methods
                if [ "$EUID" -eq 0 ]; then
                    if get_sensor_data_powermetrics cpu_temp gpu_temp fan_rpm cpu_freq c_plimit c_prochot c_thermlvl; then
                        log "${GREEN}[监控] 传感器数据采集成功 (powermetrics)${NC}" >&2
                    else
                        log "${YELLOW}[监控] 传感器数据采集失败，使用回退方法${NC}" >&2
                        cpu_temp=$(ioreg -l 2>/dev/null | grep -i '"Temperature"' | grep -oE '[0-9]+' | head -1)
                        fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan"' | grep -oE '[0-9]+' | head -1)
                        cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
                    fi
                else
                    cpu_temp=$(ioreg -l | grep -i "temperature" | grep -oE '[0-9]+' | head -1 || echo "0")
                    fan_rpm=$(ioreg -l | grep -i "fan" | grep -oE '[0-9]+' | head -1 || echo "0")
                    cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
                fi
            fi

            # Validate and correct values
            if ! echo "$cpu_temp" | grep -qE '^[0-9]+$' || [ "$cpu_temp" -lt 0 ] || [ "$cpu_temp" -gt 120 ]; then cpu_temp="0"; fi
            if ! echo "$fan_rpm" | grep -qE '^[0-9]+$' || [ "$fan_rpm" -lt 0 ] || [ "$fan_rpm" -gt 10000 ]; then fan_rpm="0"; fi
            if ! echo "$cpu_freq" | grep -qE '^[0-9]+$' || [ "$cpu_freq" -lt 400 ] || [ "$cpu_freq" -gt 6000 ]; then cpu_freq="800"; fi

            ktask=$(top -l 1 | awk '/kernel_task/ {print $3}' | head -1 | tr -d '%')
            [ -z "$ktask" ] && ktask="0.0"
            cpu_limit=$(pmset -g therm 2>/dev/null | grep "CPU_Speed_Limit" | awk -F'=' '{print $2}' | tr -d ' ' || echo "100")
            [ -z "$cpu_limit" ] && cpu_limit="100"

            echo "$ts,$cpu_temp,$gpu_temp,$fan_rpm,$gpu_act,$cpu_freq,$ktask,$cpu_limit,$c_plimit,$c_prochot,$c_thermlvl" >> "$THERMAL_LOG"

            sleep $SAMPLE_INTERVAL
        done
    ) & THERM_PID=$!
    log "${GREEN}[监控] 连续温度监控已启动${NC}"
}

# Continuous power monitoring function
start_power_monitor_continuous() {
    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            cpu_pkg_power="N/A"
            gpu_pkg_power="N/A"
            mem_power="N/A"

            if [ $CONTINUOUS_MONITORING -eq 1 ]; then
                if get_continuous_power_data cpu_pkg_power gpu_pkg_power mem_power; then
                    log "${GREEN}[监控] 连续功率数据采集成功${NC}" >&2
                else
                    log "${YELLOW}[监控] 连续功率数据采集失败${NC}" >&2
                fi
            else
                if [ "$EUID" -eq 0 ]; then
                    if get_power_data_powermetrics cpu_pkg_power gpu_pkg_power mem_power; then
                        log "${GREEN}[监控] 功率数据采集成功 (powermetrics)${NC}" >&2
                    else
                        log "${YELLOW}[监控] 功率数据采集失败${NC}" >&2
                    fi
                fi
            fi

            echo "$ts,$cpu_pkg_power,$gpu_pkg_power,$mem_power" >> "$POWER_LOG"

            if [ "$cpu_pkg_power" != "N/A" ]; then
                log "${GREEN}[监控] 功耗 - CPU: ${cpu_pkg_power}W, GPU: ${gpu_pkg_power}W${NC}" >&2
            fi

            sleep $SAMPLE_INTERVAL
        done
    ) & POWER_PID=$!
    log "${GREEN}[监控] 连续功率监控已启动${NC}"
}