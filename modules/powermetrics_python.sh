#!/bin/bash

# ==============================================================================
# Powermetrics Python 集成模块
# 提供优化的 powermetrics 数据采集和处理
# ==============================================================================

# Python 脚本路径
PYTHON_PARSER="$MODULES_DIR/powermetrics_parser.py"

# 检查 Python 解析器是否可用
check_python_powermetrics() {
    if [[ "$PYTHON_MONITOR" != "true" ]]; then
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log "${YELLOW}[监控] Python3 不可用，禁用 Python powermetrics 模式${NC}"
        return 1
    fi

    if [ ! -f "$PYTHON_PARSER" ]; then
        log "${YELLOW}[监控] Python powermetrics 解析器未找到: $PYTHON_PARSER${NC}"
        return 1
    fi

    # 测试 Python 解析器
    if python3 "$PYTHON_PARSER" >/dev/null 2>&1; then
        log "${GREEN}[监控] Python powermetrics 解析器可用${NC}"
        return 0
    else
        log "${YELLOW}[监控] Python powermetrics 解析器测试失败${NC}"
        return 1
    fi
}

# 使用 Python 获取传感器数据
get_sensor_data_python() {
    local cpu_temp_var="$1"
    local gpu_temp_var="$2"
    local fan_rpm_var="$3"
    local cpu_freq_var="$4"
    local c_plimit_var="$5"
    local c_prochot_var="$6"
    local c_thermlvl_var="$7"

    # 初始化返回值
    eval "$cpu_temp_var='0'"
    eval "$gpu_temp_var='0'"
    eval "$fan_rpm_var='0'"
    eval "$cpu_freq_var='0'"
    eval "$c_plimit_var='0.00'"
    eval "$c_prochot_var='0'"
    eval "$c_thermlvl_var='0'"

    # 使用 Python 解析器获取数据
    local python_output
    python_output=$(python3 "$PYTHON_PARSER" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$python_output" ]; then
        # 提取传感器数据
        local cpu_temp=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(int(data.get('cpu_temp', 0))) if 'cpu_temp' in data else print(0)
")
        local gpu_temp=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(int(data.get('gpu_temp', 0))) if 'gpu_temp' in data else print(0)
")
        local fan_rpm=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(int(data.get('fan_rpm', 0))) if 'fan_rpm' in data else print(0)
")
        local cpu_freq=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(int(data.get('cpu_frequency', 0))) if 'cpu_frequency' in data else print(0)
")
        local cpu_plimit=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('cpu_plimit', 0.0)) if 'cpu_plimit' in data else print(0.0)
")
        local prochots=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(int(data.get('prochots', 0))) if 'prochots' in data else print(0)
")
        local thermal_level=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(int(data.get('thermal_level', 0))) if 'thermal_level' in data else print(0)
")

        # 验证并设置返回值
        if [ -n "$cpu_temp" ] && [ "$cpu_temp" -ge 0 ] && [ "$cpu_temp" -le 120 ]; then
            eval "$cpu_temp_var='$cpu_temp'"
        fi
        if [ -n "$gpu_temp" ] && [ "$gpu_temp" -ge 0 ] && [ "$gpu_temp" -le 120 ]; then
            eval "$gpu_temp_var='$gpu_temp'"
        fi
        if [ -n "$fan_rpm" ] && [ "$fan_rpm" -ge 0 ] && [ "$fan_rpm" -le 10000 ]; then
            eval "$fan_rpm_var='$fan_rpm'"
        fi
        if [ -n "$cpu_freq" ] && [ "$cpu_freq" -ge 400 ] && [ "$cpu_freq" -le 6000 ]; then
            eval "$cpu_freq_var='$cpu_freq'"
        fi
        if [ -n "$cpu_plimit" ]; then
            eval "$c_plimit_var='$cpu_plimit'"
        fi
        if [ -n "$prochots" ]; then
            eval "$c_prochot_var='$prochots'"
        fi
        if [ -n "$thermal_level" ]; then
            eval "$c_thermlvl_var='$thermal_level'"
        fi

        return 0
    fi

    return 1
}

# 使用 Python 获取功率数据
get_power_data_python() {
    local cpu_power_var="$1"
    local gpu_power_var="$2"
    local mem_power_var="$3"

    # 初始化返回值
    eval "$cpu_power_var='N/A'"
    eval "$gpu_power_var='N/A'"
    eval "$mem_power_var='N/A'"

    # 使用 Python 获取功率数据
    local python_output
    python_output=$(python3 -c "
import sys
sys.path.append('$MODULES_DIR')
from powermetrics_parser import PowermetricsParser
parser = PowermetricsParser()
data, success = parser.get_power_data()
if success:
    print(json.dumps(data))
" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$python_output" ]; then
        # 提取功率数据
        local cpu_power=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('cpu_power', 'N/A')) if 'cpu_power' in data else print('N/A')
")
        local gpu_power=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('gpu_power', 'N/A')) if 'gpu_power' in data else print('N/A')
")
        local mem_power=$(echo "$python_output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('memory_power', 'N/A')) if 'memory_power' in data else print('N/A')
")

        # 验证并设置返回值
        if [ -n "$cpu_power" ] && [ "$cpu_power" != "N/A" ]; then
            # 限制功率范围
            if (( $(echo "$cpu_power > 150" | bc -l 2>/dev/null || echo 0) )); then
                cpu_power="150.0"
            fi
            eval "$cpu_power_var='$cpu_power'"
        fi
        if [ -n "$gpu_power" ] && [ "$gpu_power" != "N/A" ]; then
            # 限制功率范围
            if (( $(echo "$gpu_power > 100" | bc -l 2>/dev/null || echo 0) )); then
                gpu_power="100.0"
            fi
            eval "$gpu_power_var='$gpu_power'"
        fi
        if [ -n "$mem_power" ] && [ "$mem_power" != "N/A" ]; then
            # 限制功率范围
            if (( $(echo "$mem_power > 25" | bc -l 2>/dev/null || echo 0) )); then
                mem_power="25.0"
            fi
            eval "$mem_power_var='$mem_power'"
        fi

        return 0
    fi

    return 1
}

# Python 版本的温度监控函数
start_thermal_monitor_python() {
    # 检查 Python 解析器是否可用
    if ! check_python_powermetrics; then
        return 1
    fi

    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            # 获取 GPU 数据（使用传统方法，因为 powermetrics 不总是提供 GPU 数据）
            gpu_temp="0"
            gpu_act="0"

            # 方法1: ioreg PerformanceStatistics
            gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "temperature" | head -1)
            if [ -n "$gpu_line" ]; then
                gpu_temp=$(echo "$gpu_line" | grep -o 'Temperature(C)=[0-9]*' | grep -oE '[0-9]+' || echo "0")
                gpu_act=$(echo "$gpu_line" | grep -o 'GPU Activity(%)=[0-9]*' | grep -oE '[0-9]+' || echo "0")
            fi

            # 方法2: SMC via ioreg (fallback)
            if [ "$gpu_temp" = "0" ]; then
                smc_gpu_temp=$(ioreg -l | grep -i "gpu-temp" | grep -oE '[0-9]+' | head -1)
                if [ -n "$smc_gpu_temp" ]; then
                    gpu_temp="$smc_gpu_temp"
                fi
            fi

            [ -z "$gpu_temp" ] && gpu_temp="0"
            [ -z "$gpu_act" ] && gpu_act="0"

            # 初始化变量
            cpu_freq="0"
            cpu_temp="0"
            fan_rpm="0"
            c_plimit="0.00"
            c_prochot="0"
            c_thermlvl="0"

            if [ "$EUID" -eq 0 ]; then
                # 使用 Python 获取传感器数据
                if get_sensor_data_python cpu_temp gpu_temp fan_rpm cpu_freq c_plimit c_prochot c_thermlvl; then
                    log "${GREEN}[监控] Python 传感器数据采集成功${NC}" >&2
                else
                    log "${YELLOW}[监控] Python 传感器数据采集失败，使用回退方法${NC}" >&2
                    # 回退到 ioreg
                    cpu_temp=$(ioreg -l 2>/dev/null | grep -i '"Temperature"' | grep -oE '[0-9]+' | head -1)
                    fan_rpm=$(ioreg -l 2>/dev/null | grep -i '"Fan"' | grep -oE '[0-9]+' | head -1)
                    cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
                fi
            else
                # 非 root 用户回退方案
                cpu_temp=$(ioreg -l | grep -i "temperature" | grep -oE '[0-9]+' | head -1 || echo "0")
                fan_rpm=$(ioreg -l | grep -i "fan" | grep -oE '[0-9]+' | head -1 || echo "0")
                cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "0")
            fi

            # 验证数据
            if ! echo "$cpu_temp" | grep -qE '^[0-9]+$' || [ "$cpu_temp" -lt 0 ] || [ "$cpu_temp" -gt 120 ]; then cpu_temp="0"; fi
            if ! echo "$fan_rpm" | grep -qE '^[0-9]+$' || [ "$fan_rpm" -lt 0 ] || [ "$fan_rpm" -gt 10000 ]; then fan_rpm="0"; fi
            if ! echo "$cpu_freq" | grep -qE '^[0-9]+$' || [ "$cpu_freq" -lt 400 ] || [ "$cpu_freq" -gt 6000 ]; then cpu_freq="800"; fi

            # 获取内核任务占用率
            ktask=$(top -l 1 | awk '/kernel_task/ {print $3}' | head -1 | tr -d '%')
            [ -z "$ktask" ] && ktask="0"

            # 获取速度限制
            cpu_limit=$(sysctl -n kern.sched_freq_highest 2>/dev/null | awk '{printf "%.0f", $1/1000000}' || echo "100")
            [ -z "$cpu_limit" ] && cpu_limit="100"

            # 记录数据
            echo "$ts,$cpu_temp,$gpu_temp,$fan_rpm,$gpu_act,$cpu_freq,$ktask,$cpu_limit,$c_plimit,$c_prochot,$c_thermlvl" >> "$THERMAL_LOG"

            sleep $SAMPLE_INTERVAL
        done
    ) & THERM_PID=$!
    log "${GREEN}[监控] Python 温度监控已启动${NC}"
    return 0
}

# Python 版本的功率监控函数
start_power_monitor_python() {
    # 检查 Python 解析器是否可用
    if ! check_python_powermetrics; then
        return 1
    fi

    (
        while [ $EARLY_STOP -eq 0 ] && [ ! -f /tmp/stress_early_stop.flag ]; do
            ts=$(date +%H:%M:%S)

            if [ "$EUID" -eq 0 ]; then
                # 使用 Python 获取功率数据
                cpu_pkg_power="N/A"
                gpu_pkg_power="N/A"
                mem_power="N/A"

                if get_power_data_python cpu_pkg_power gpu_pkg_power mem_power; then
                    log "${GREEN}[监控] Python 功率数据采集成功${NC}" >&2
                else
                    log "${YELLOW}[监控] Python 功率数据采集失败${NC}" >&2
                fi
            else
                # 非 root 用户回退
                cpu_pkg_power="N/A"
                gpu_pkg_power="N/A"
                mem_power="N/A"
            fi

            # 记录功率数据
            echo "$ts,$cpu_pkg_power,$gpu_pkg_power,$mem_power" >> "$POWER_LOG"

            # 显示功率信息
            if [ "$cpu_pkg_power" != "N/A" ]; then
                log "${GREEN}[监控] 功耗 - CPU: ${cpu_pkg_power}W, GPU: ${gpu_pkg_power}W${NC}" >&2
            fi

            sleep $SAMPLE_INTERVAL
        done
    ) & POWER_PID=$!
    log "${GREEN}[监控] Python 功率监控已启动${NC}"
    return 0
}