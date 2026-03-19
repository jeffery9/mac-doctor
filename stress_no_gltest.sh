#!/bin/bash

# ==============================================================================
# macOS Intel CPU + GPU 压力测试及性能诊断工具 (NO GLTEST VERSION) - Enhanced v6.0
# Uses OpenSSL & QuickLook for Load Generation
# 增强诊断：分阶段测试 (CPU单烤 -> GPU单烤 -> 双烤)，找出导致降频的具体硬件瓶颈
# 增强选项：支持选择仅测试特定硬件
# ==============================================================================

REPORT_DIR="/tmp/stress_diag_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"
LOG_FILE="$REPORT_DIR/stress_summary.log"
VOLTAGE_LOG="$REPORT_DIR/voltage_curve.csv"
KERNEL_LOG="$REPORT_DIR/kernel_errors.log"
THERMAL_LOG="$REPORT_DIR/thermal_log.csv"
POWER_LOG="$REPORT_DIR/power_log.csv"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
TEST_DURATION=900           # 15 分钟
PHASE_DURATION=$((TEST_DURATION / 3))
VOLTAGE_DROP_THRESHOLD=800  # mV 电压降阈值
TEMP_WARN=85                # °C 警告温度
TEMP_CRIT=95                # °C 临界温度
SAMPLE_INTERVAL=2           # 采样间隔 (秒)

# Global flags
VOLTAGE_WARNING=0
THERMAL_WARNING=0
KERNEL_TASK_WARNING=0
KERNEL_ERROR=0
TEST_COMPLETED=0
EARLY_STOP=0

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
header() { log ""; log "${CYAN}============================================================${NC}"; log "${CYAN}$1${NC}"; log "${CYAN}============================================================${NC}"; }

# Cleanup function
cleanup() {
    log "${YELLOW}[清理] 停止所有负载进程...${NC}"
    jobs -p | xargs -r kill -9 2>/dev/null
    pkill -9 openssl 2>/dev/null
    pkill -9 dd 2>/dev/null
    pkill -9 qlmanage 2>/dev/null
    pkill -9 sips 2>/dev/null
    rm -f /tmp/stress_*.tiff /tmp/stress_*.png /tmp/gpu_stress_* /tmp/gpu_base_*.ppm /tmp/gpu_resize_* /tmp/*_resize_*.png 2>/dev/null
    rm -rf /tmp/ql_* /tmp/ql_tmp* /tmp/ql_r* /tmp/ql_t* /tmp/mem_stress_* /tmp/stress_cpu_run /tmp/stress_gpu_run 2>/dev/null
}

handle_interrupt() {
    log ""
    log "${RED}======================================================${NC}"
    log "${RED}  >>> 检测到提前终止信号 (Ctrl+C) <<<${NC}"
    log "${RED}  正在安全停止所有负载测试，并生成当前收集到的诊断报告...${NC}"
    log "${RED}======================================================${NC}"
    EARLY_STOP=1
}

trap cleanup EXIT
trap handle_interrupt INT TERM

# Check sudo
check_sudo() {
    if [ "$EUID" -eq 0 ]; then
        log "${GREEN}[权限] 已获取 root 权限，可读取 CPU 温度、风扇和真实频率数据${NC}"
        return 0
    else
        log "${RED}[提示] 强烈建议使用 sudo 运行本工具以获取真实的诊断数据 (温度/频率/风扇)${NC}"
        log "${BLUE}请使用：sudo $0${NC}"
        return 1
    fi
}

clear
log "${BLUE}========================================${NC}"
log "${BLUE}  macOS Intel 性能诊断与压力测试工具${NC}"
log "${BLUE}  v6.0 (支持自定义阶段与硬件隔离诊断)${NC}"
log "${BLUE}========================================${NC}"
log ""
log "输出目录：$REPORT_DIR (测试结束后自动清理)"
log ""

# Show system info
log "${CYAN}=== 系统信息 ===${NC}"
cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "Unknown")
mem_size=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.1f GB", $1/1024/1024/1024}')
macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "Unknown")
gpu_info=$(system_profiler SPDisplaysDataType 2>/dev/null | awk '/Chipset Model/ {print substr($0, index($0, $3))}' | paste -sd ", " -)

log "CPU: $cpu_model"
log "核心数：$cpu_cores"
log "内存：$mem_size"
log "macOS: $macos_ver"
log "GPU: $gpu_info"
log ""

check_sudo
log ""

log "${RED}⚠️  警告：${NC}"
log "  - 保存所有工作，系统可能崩溃或重启"
log "  - 风扇会高速运转，噪音很大"
log "  - 设备会变热，电池老化设备可能意外关机"
log ""

log "${CYAN}请选择测试模式：${NC}"
log "  1) 完整分阶段测试 (CPU单烤 -> 冷却 -> GPU单烤 -> 冷却 -> 极限双烤) [全面诊断, 推荐, ~21分钟]"
log "  2) 仅测试 CPU (~5分钟)"
log "  3) 仅测试 GPU (~5分钟)"
log "  4) 仅测试 极限双烤 (CPU+GPU) (~5分钟)"
read -p "请输入选项 [1-4] 并按回车: " choice

case $choice in
    1) TEST_MODE="ALL" ;;
    2) TEST_MODE="CPU" ;;
    3) TEST_MODE="GPU" ;;
    4) TEST_MODE="DUAL" ;;
    *) log "${RED}无效选项，退出。${NC}"; exit 0 ;;
esac

log ""
log "${YELLOW}5 秒后开始测试，请保存工作...${NC}"
sleep 5

START_TIME=$(date +%s)

header "1. 基线检查"

# Battery check using ioreg LegacyBatteryInfo
log "${CYAN}=== 电池状态 ===${NC}"

bat_legacy=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"LegacyBatteryInfo"' | head -1)

if [ -n "$bat_legacy" ]; then
    bat_cycle=$(echo "$bat_legacy" | grep -oE '"Cycle Count"=[0-9]+' | grep -oE '[0-9]+')
    
    bat_data=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"BatteryData"' | head -1)
    max_cap=$(echo "$bat_data" | grep -oE '"MaxCapacity"=[0-9]+' | grep -oE '[0-9]+')
    design_cap=$(echo "$bat_data" | grep -oE '"DesignCapacity"=[0-9]+' | grep -oE '[0-9]+')
    
    if [ -n "$max_cap" ] && [ -n "$design_cap" ] && [ "$design_cap" -gt 0 ]; then
        health_pct=$((max_cap * 100 / design_cap))
        if [ "$health_pct" -ge 80 ]; then bat_cond="Good"
        elif [ "$health_pct" -ge 50 ]; then bat_cond="Fair"
        elif [ "$health_pct" -ge 30 ]; then bat_cond="Poor"
        else bat_cond="Service Recommended"; fi
    else
        bat_cond="Unknown"
        health_pct=0
    fi
    
    log "${BLUE}电池健康度:${NC} ${health_pct}%"
    log "${BLUE}电池状态:${NC} $bat_cond"
    log "${BLUE}循环次数:${NC} ${bat_cycle:-0}"
else
    log "${RED}✗ 无法读取电池信息${NC}"
fi

if [[ "$bat_cond" == "Service Recommended" ]] || [[ "$bat_cond" == "Replace Now" ]]; then
    log "${RED}>>> 警告：电池需要更换！电池老化是导致 CPU 严重降频和突发关机的主要原因！${NC}"
fi

ac_power=$(pmset -g batt 2>/dev/null | grep -o "AC attached" || echo "On Battery")
log "电源状态：$ac_power"

if [[ "$ac_power" != "AC attached" ]]; then
    log "${RED}>>> 警告：未连接电源适配器！这会导致电池输出压力巨大！${NC}"
fi

# Initial readings
init_vol=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"Voltage"' | grep -v 'Adapter' | grep -v 'Legacy' | head -1 | awk '{print $NF}' | tr -d ',')
if [ -z "$init_vol" ] || [ "$init_vol" -lt 8000 ] 2>/dev/null || [ "$init_vol" -gt 18000 ] 2>/dev/null; then
    init_vol=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"BatteryData"' | grep -oE '"Voltage"=[0-9]+' | head -1 | grep -oE '[0-9]+')
fi
if [ -n "$init_vol" ] && [ "$init_vol" -gt 8000 ] 2>/dev/null && [ "$init_vol" -lt 18000 ] 2>/dev/null; then
    log "初始电压：${init_vol}mV"
else
    init_vol=""
fi

header "2. 启动诊断监控"

# Initialize CSV logs
echo "Timestamp,Voltage_mV,Current_mA" > "$VOLTAGE_LOG"
echo "Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Activity_%,CPU_Freq_MHz,Kernel_Task_%,CPU_Speed_Limit_%,CPU_Plimit,Prochots,Thermal_Level" > "$THERMAL_LOG"
echo "Timestamp,Package_W,GPU_W" > "$POWER_LOG"
> "$KERNEL_LOG"

# Voltage & Current monitor
(
    while [ $EARLY_STOP -eq 0 ]; do
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

# Combined Thermal & Throttling monitor
(
    while [ $EARLY_STOP -eq 0 ]; do
        ts=$(date +%H:%M:%S)
        
        gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "temperature" | head -1)
        gpu_temp=$(echo "$gpu_line" | grep -o 'Temperature(C)=[0-9]*' | grep -oE '[0-9]+' || echo "0")
        [ -z "$gpu_temp" ] && gpu_temp="0"
        
        gpu_act=$(echo "$gpu_line" | grep -o 'GPU Activity(%)=[0-9]*' | grep -oE '[0-9]+' || echo "0")
        [ -z "$gpu_act" ] && gpu_act="0"
        
        cpu_freq="0"
        cpu_temp="0"
        fan_rpm="0"
        c_plimit="0.00"
        c_prochot="0"
        c_thermlvl="0"
        
        if [ "$EUID" -eq 0 ]; then
            pm_out=$(powermetrics -n 1 -i 100 --samplers smc,cpu_power 2>/dev/null)
            c_tmp=$(echo "$pm_out" | awk '/CPU die temperature/ {print $4; exit}' | cut -d. -f1)
            [ -n "$c_tmp" ] && cpu_temp="$c_tmp"
            f_rpm=$(echo "$pm_out" | awk '/Fan:/ {print $2; exit}' || echo "$pm_out" | awk '/Fan / {print $2; exit}')
            [ -n "$f_rpm" ] && fan_rpm="$f_rpm"
            c_freq=$(echo "$pm_out" | awk '/CPU [0-9]* average frequency/ {sum+=$5; count++} END {if(count>0) print int(sum/count)}')
            if [ -z "$c_freq" ] || [ "$c_freq" -eq 0 ]; then
                c_freq=$(echo "$pm_out" | awk '/CPU average frequency/ {print $4; exit}')
            fi
            [ -n "$c_freq" ] && cpu_freq="$c_freq"
            
            c_pl=$(echo "$pm_out" | awk '/CPU Plimit:/ {print $3; exit}')
            [ -n "$c_pl" ] && c_plimit="$c_pl"
            c_pr=$(echo "$pm_out" | awk '/Number of prochots:/ {print $4; exit}')
            [ -n "$c_pr" ] && c_prochot="$c_pr"
            c_tl=$(echo "$pm_out" | awk '/CPU Thermal level:/ {print $4; exit}')
            [ -n "$c_tl" ] && c_thermlvl="$c_tl"
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

# Power monitor
(
    while [ $EARLY_STOP -eq 0 ]; do
        ts=$(date +%H:%M:%S)
        gpu_line=$(ioreg -l 2>/dev/null | grep '"PerformanceStatistics"' | grep -i "total power" | head -1)
        gpu_power=$(echo "$gpu_line" | grep -o 'Total Power(W)=[0-9]*' | grep -oE '[0-9]+' || echo "N/A")
        [ -z "$gpu_power" ] && gpu_power="N/A"
        echo "$ts,N/A,$gpu_power" >> "$POWER_LOG"
        sleep $SAMPLE_INTERVAL
    done
) & POWER_PID=$!

if [ "$EUID" -eq 0 ]; then
    (
        log stream --predicate 'eventMessage contains "droop" OR eventMessage contains "hang" OR eventMessage contains "overcurrent" OR eventMessage contains "thermal"' --style syslog 2>/dev/null | while IFS= read -r line; do
            echo "$(date +%H:%M:%S) $line" >> "$KERNEL_LOG"
        done
    ) & LOG_PID=$!
    log "${GREEN}[监控] 内核警告日志已启动${NC}"
fi

# ================= 负载控制函数 =================
start_cpu_stress() {
    log "${CYAN}--- [启动] CPU 100% 压力测试 ---${NC}"
    CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    THREADS=$((CORES * 2))
    touch /tmp/stress_cpu_run
    (
        for i in $(seq 1 $THREADS); do
            while [ -f /tmp/stress_cpu_run ]; do
                openssl speed -elapsed -evp aes-256-cbc > /dev/null 2>&1
            done &
        done
        wait
    ) & CPU_PID=$!
}

stop_cpu_stress() {
    log "${YELLOW}--- [停止] CPU 压力测试 ---${NC}"
    rm -f /tmp/stress_cpu_run
    pkill -9 openssl 2>/dev/null
    kill -9 $CPU_PID 2>/dev/null
}

start_gpu_stress() {
    log "${CYAN}--- [启动] GPU 高负载运算测试 (原生 Metal Compute Shader) ---${NC}"
    touch /tmp/stress_gpu_run
    
    # 获取当前脚本所在目录
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    SWIFT_FILE="$SCRIPT_DIR/gpu_stress_test.swift"
    
    if [ ! -f "$SWIFT_FILE" ]; then
        log "${RED}错误：找不到 GPU 测试脚本 ($SWIFT_FILE)${NC}"
        log "${YELLOW}跳过 GPU 测试。${NC}"
        return
    fi
    
    # 编译基于原生 Metal 的 GPU 计算压力测试工具
    swiftc "$SWIFT_FILE" -o /tmp/gpu_stress_bin >/dev/null 2>&1
    
    (
        # 启动 4 个并行 GPU 计算进程，这会彻底吃满所有可用 GPU 核心
        for i in 1 2 3 4; do
            while [ -f /tmp/stress_gpu_run ]; do
                /tmp/gpu_stress_bin >/dev/null 2>&1
            done &
        done
        wait
    ) & GPU_PID=$!
}

stop_gpu_stress() {
    log "${YELLOW}--- [停止] GPU 压力测试 ---${NC}"
    rm -f /tmp/stress_gpu_run
    pkill -9 gpu_stress_bin 2>/dev/null
    kill -9 $GPU_PID 2>/dev/null
    rm -f /tmp/gpu_stress* 2>/dev/null
}

start_mem_stress() {
    log "${CYAN}--- [启动] 内存分配测试 ---${NC}"
    MEM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')
    MEM_STRESS=$((MEM_GB / 4))
    [ $MEM_STRESS -lt 1 ] && MEM_STRESS=1
    [ $MEM_STRESS -gt 4 ] && MEM_STRESS=4
    (
        for i in $(seq 1 $MEM_STRESS); do
            dd if=/dev/zero of=/tmp/mem_stress_$i bs=1m count=1024 2>/dev/null &
        done
        wait
        rm -f /tmp/mem_stress_* 2>/dev/null
    ) & MEM_PID=$!
}

header "3. 诊断运行中"

PAUSE_DURATION=180

if [ "$TEST_MODE" == "ALL" ]; then
    TOTAL_DURATION=$((PHASE_DURATION * 3 + PAUSE_DURATION * 2))
    log "总测试时长：$((TOTAL_DURATION/60)) 分钟，包含两次 3 分钟的冷却暂停："
    log "阶段 1: 纯 CPU 单烤测试 ($((PHASE_DURATION/60)) 分钟)"
    log "暂停 1: 冷却恢复 ($((PAUSE_DURATION/60)) 分钟)"
    log "阶段 2: 纯 GPU 单烤测试 ($((PHASE_DURATION/60)) 分钟)"
    log "暂停 2: 冷却恢复 ($((PAUSE_DURATION/60)) 分钟)"
    log "阶段 3: CPU + GPU + 内存 极限双烤 ($((PHASE_DURATION/60)) 分钟)"
    log ""
    
    log "${CYAN}======================================================${NC}"
    log "${CYAN}  ▶ 进入阶段 1：纯 CPU 单烤压力测试${NC}"
    log "${CYAN}======================================================${NC}"
    start_cpu_stress
else
    TOTAL_DURATION=$PHASE_DURATION
    log "总测试时长：$((TOTAL_DURATION/60)) 分钟"
    if [ "$TEST_MODE" == "CPU" ]; then 
        log "模式: 仅 CPU 单烤测试"
        start_cpu_stress
    fi
    if [ "$TEST_MODE" == "GPU" ]; then 
        log "模式: 仅 GPU 单烤测试"
        start_gpu_stress
    fi
    if [ "$TEST_MODE" == "DUAL" ]; then 
        log "模式: 仅 极限满载双烤测试"
        start_cpu_stress
        start_gpu_stress
        start_mem_stress
    fi
    log ""
fi

for ((i=1; i<=TOTAL_DURATION; i++)); do
    if [ $EARLY_STOP -eq 1 ]; then
        log "${YELLOW}正在中止等待循环并收集最终数据...${NC}"
        break
    fi
    sleep 1
    
    if [ "$TEST_MODE" == "ALL" ]; then
        # 阶段状态切换控制
        if [ $i -eq $((PHASE_DURATION + 1)) ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入冷却暂停：停止负载，等待 3 分钟以恢复基线温度${NC}"
            log "${CYAN}======================================================${NC}"
            stop_cpu_stress
            wait $CPU_PID 2>/dev/null
        elif [ $i -eq $((PHASE_DURATION + PAUSE_DURATION + 1)) ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入阶段 2：纯 GPU 单烤压力测试${NC}"
            log "${CYAN}======================================================${NC}"
            start_gpu_stress
        elif [ $i -eq $((PHASE_DURATION * 2 + PAUSE_DURATION + 1)) ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入冷却暂停：停止负载，等待 3 分钟以恢复基线温度${NC}"
            log "${CYAN}======================================================${NC}"
            stop_gpu_stress
            wait $GPU_PID 2>/dev/null
        elif [ $i -eq $((PHASE_DURATION * 2 + PAUSE_DURATION * 2 + 1)) ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入阶段 3：极限满载 (CPU + GPU 双烤)${NC}"
            log "${CYAN}======================================================${NC}"
            start_cpu_stress
            start_gpu_stress
            start_mem_stress
        fi
    fi

    if [ $((i % 10)) -eq 0 ]; then
        elapsed=$((i/60))
        remaining=$(((TOTAL_DURATION-i)/60))
        
        # Determine Current Phase Name
        if [ "$TEST_MODE" == "ALL" ]; then
            if [ $i -le $PHASE_DURATION ]; then
                current_phase="阶段1: CPU单烤"
            elif [ $i -le $((PHASE_DURATION + PAUSE_DURATION)) ]; then
                current_phase="冷却恢复中 (准备GPU单烤)"
            elif [ $i -le $((PHASE_DURATION * 2 + PAUSE_DURATION)) ]; then
                current_phase="阶段2: GPU单烤"
            elif [ $i -le $((PHASE_DURATION * 2 + PAUSE_DURATION * 2)) ]; then
                current_phase="冷却恢复中 (准备极限双烤)"
            else
                current_phase="阶段3: 极限双烤"
            fi
        else
            if [ "$TEST_MODE" == "CPU" ]; then current_phase="纯CPU单烤"; fi
            if [ "$TEST_MODE" == "GPU" ]; then current_phase="纯GPU单烤"; fi
            if [ "$TEST_MODE" == "DUAL" ]; then current_phase="极限双烤"; fi
        fi

        # Retrieve latest telemetry
        if [ -f "$THERMAL_LOG" ]; then
            latest_data=$(tail -1 "$THERMAL_LOG" 2>/dev/null)
            c_t=$(echo "$latest_data" | cut -d',' -f2)
            g_t=$(echo "$latest_data" | cut -d',' -f3)
            f_rpm=$(echo "$latest_data" | cut -d',' -f4)
            c_freq=$(echo "$latest_data" | cut -d',' -f6)
            ktask=$(echo "$latest_data" | cut -d',' -f7)
            c_lim=$(echo "$latest_data" | cut -d',' -f8)
            c_plimit=$(echo "$latest_data" | cut -d',' -f9)
            c_prochot=$(echo "$latest_data" | cut -d',' -f10)
            c_thermlvl=$(echo "$latest_data" | cut -d',' -f11)
            g_act=$(echo "$latest_data" | cut -d',' -f5)
            
            log "${BLUE}[${elapsed}分] 剩余 ${remaining}分 | ${current_phase}：${NC}"
            
            log_str="  CPU: 温度 ${c_t}°C | 频率 ${c_freq}MHz | Plimit ${c_plimit} | 限速器 ${c_lim}% | Kernel_Task占用 ${ktask}%"
            if [ "$g_t" -gt 0 ]; then
                log_str="$log_str | GPU: ${g_t}°C (负载 ${g_act}%) | 风扇: ${f_rpm} RPM"
            else
                log_str="$log_str | 风扇: ${f_rpm} RPM"
            fi
            log "$log_str"
            
            # Diagnose Hardware Plimit (Battery/Power Delivery)
            if [ -n "$c_plimit" ] && [ "$c_plimit" != "0.00" ]; then
                log "${RED}  >>> [致命供电警告] CPU Plimit 高达 ${c_plimit}！主板因供电崩溃或极限高温，正在强行掐断 CPU 电源！${NC}"
                VOLTAGE_WARNING=1
            fi
            
            # Diagnose Hardware Prochot (Thermal Limit)
            if [ -n "$c_prochot" ] && [ "$c_prochot" != "0" ]; then
                log "${RED}  >>> [致命高温警告] PROCHOT 触发！芯片已达极限危险温度，已强制切断时钟频率自我保护！${NC}"
                THERMAL_WARNING=1
            fi

            # Diagnose CPU Throttling (OS Level)
            if [ -n "$c_lim" ] && [ "$c_lim" -lt 80 ]; then
                log "${RED}  >>> [降频警告] CPU 速度被系统底层强制限制在 ${c_lim}%！${NC}"
                THERMAL_WARNING=1
            fi
            
            # Diagnose Kernel Task preemptive cooling
            ktask_int=$(echo "$ktask" | awk '{print int($1)}')
            if [ -n "$ktask_int" ] && [ "$ktask_int" -gt 100 ]; then
                log "${RED}  >>> [性能杀手] kernel_task 极高 (${ktask}%)！系统正强制阻断 CPU 计算以求降温！${NC}"
                KERNEL_TASK_WARNING=1
            fi
            
            # Diagnose Frequency dropping
            if [ -n "$c_freq" ] && [ "$c_freq" -gt 0 ] && [ "$c_freq" -lt 1200 ]; then
                 log "${RED}  >>> [低频警告] CPU 跌破基础频率，正面临 ${c_freq}MHz 严重物理降频！${NC}"
            fi

            if [ -n "$c_t" ] && [ "$c_t" -gt "$TEMP_CRIT" ] 2>/dev/null; then
                log "${RED}  >>> [过热警告] CPU 温度撞墙：${c_t}°C${NC}"
                THERMAL_WARNING=1
            elif [ -n "$c_t" ] && [ "$c_t" -gt "$TEMP_WARN" ] 2>/dev/null; then
                log "${YELLOW}  >>> [温度提示] CPU 温度偏高：${c_t}°C${NC}"
            fi
        fi

        # Voltage check
        if [ -n "$init_vol" ]; then
            cur_vol=$(tail -1 "$VOLTAGE_LOG" 2>/dev/null | cut -d',' -f2)
            if [ -n "$cur_vol" ] && [ "$cur_vol" -gt 8000 ] 2>/dev/null && [ "$cur_vol" -lt 18000 ] 2>/dev/null; then
                if [ "$init_vol" -gt "$cur_vol" ]; then drop=$((init_vol - cur_vol)); else drop=0; fi
                if [ "$drop" -gt "$VOLTAGE_DROP_THRESHOLD" ] && [ $VOLTAGE_WARNING -eq 0 ]; then
                    log "${RED}  >>> [电池警告] 电压瞬降过大：${drop}mV (供电不足导致强制降频)${NC}"
                    VOLTAGE_WARNING=1
                fi
            fi
        fi
    fi
done

TEST_COMPLETED=1
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

header "4. 测试结果及性能问题诊断"

EARLY_STOP=1
cleanup
sleep 2

# ============ VOLTAGE ANALYSIS ============
log "${CYAN}=== 电源与电压诊断 ===${NC}"
if [ -f "$VOLTAGE_LOG" ] && [ $(wc -l < "$VOLTAGE_LOG") -gt 1 ]; then
    max_v=$(tail -n +2 "$VOLTAGE_LOG" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | tail -1)
    min_v=$(tail -n +2 "$VOLTAGE_LOG" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | head -1)

    if [ -n "$max_v" ] && [ -n "$min_v" ]; then
        drop=$((max_v - min_v))
        log "最高电压：${max_v}mV"
        log "最低电压：${min_v}mV"
        log "最大压降：${drop}mV"

        if [ "$drop" -gt "$VOLTAGE_DROP_THRESHOLD" ]; then
            log "${RED}>>> 诊断：电池老化严重。满载时电压降过大 (${drop}mV)，这会触发硬件级降频 (PROCHOT) 以防断电。${NC}"
            VOLTAGE_WARNING=1
        else
            log "${GREEN}>>> 供电稳定。${NC}"
        fi
    fi
fi

# ============ THROTTLING ANALYSIS ============
log ""
log "${CYAN}=== 降频与温度诊断 ===${NC}"
if [ -f "$THERMAL_LOG" ] && [ $(wc -l < "$THERMAL_LOG") -gt 1 ]; then
    max_c_t=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | tail -1)
    min_freq=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f6 | grep -E '^[0-9]+$' | sort -n | head -1)
    max_ktask=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f7 | grep -E '^[0-9.]+$' | awk '{print int($1)}' | sort -n | tail -1)
    min_clim=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f8 | grep -E '^[0-9]+$' | sort -n | head -1)
    
    max_plimit=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f9 | grep -E '^[0-9.]+$' | sort -n | tail -1)
    sum_prochot=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f10 | grep -E '^[0-9]+$' | awk '{sum+=$1} END {print sum}')
    
    log "CPU 峰值温度：${max_c_t:-N/A}°C"
    log "CPU 最低频率：${min_freq:-N/A}MHz"
    log "系统最严重限速：${min_clim:-100}%"
    log "kernel_task 最高占用：${max_ktask:-0}%"
    log "CPU 最大 Plimit (功耗锁)：${max_plimit:-0.00}"
    log "PROCHOT 触发总次数：${sum_prochot:-0}"
    
    # Analyze Throttling Root Cause
    log ""
    log "${YELLOW}--- 性能瓶颈根因分析 (基于底层硬件传感器实证) ---${NC}"
    
    throttled=0
    
    if [ -n "$max_plimit" ] && [ "$max_plimit" != "0.00" ]; then
        log "${RED}【铁证 1】 捕捉到 CPU Plimit 高达 ${max_plimit}！主板 SMC 因检测到致命问题 (通常是电池无法提供足够电流)，在物理层面强制掐断了 CPU 电源上限！${NC}"
        throttled=1
        VOLTAGE_WARNING=1
    fi
    
    if [ -n "$sum_prochot" ] && [ "$sum_prochot" -gt 0 ]; then
        log "${RED}【铁证 2】 捕捉到 PROCHOT 触发了 ${sum_prochot} 次！芯片温度失控，触发了最后的防烧毁红线，导致瞬间断崖式降频！${NC}"
        throttled=1
        THERMAL_WARNING=1
    fi
    
    if [ -n "$min_clim" ] && [ "$min_clim" -lt 90 ]; then
        log "${RED}【间接证据】 操作系统级降频 (OS-Level Throttling)：速度被限制到了 $min_clim%。${NC}"
        throttled=1
    fi
    
    if [ -n "$max_ktask" ] && [ "$max_ktask" -gt 80 ]; then
        log "${RED}【间接证据】 kernel_task 强制降温：内核占用了 $max_ktask% 以阻挡其他应用运行。${NC}"
        throttled=1
    fi
    
    if [ -n "$max_c_t" ] && [ "$max_c_t" -ge 95 ] 2>/dev/null; then
        log "${RED}【直观表现】 存在致命的温度墙：CPU 峰值温度高达 ${max_c_t}°C，说明导热硅脂已干涸或风扇堵死，热量完全无法排出。${NC}"
        throttled=1
    fi
    
    if [ -n "$min_freq" ] && [ "$min_freq" -ge 0 ] && [ "$min_freq" -lt 1500 ]; then
        if [ "$min_freq" -eq 0 ]; then
            log "${RED}【最终后果】 频率直接跌穿至 0MHz (系统卡死)！这就是你感受到“严重卡顿”的直接原因！${NC}"
        else
            log "${RED}【最终后果】 CPU 物理降频：频率最低掉至 ${min_freq}MHz。这严重拖慢了系统运行速度。${NC}"
        fi
        throttled=1
    fi
    
    if [ "$throttled" -eq 0 ]; then
        log "${GREEN}未检测到明显的温度/供电导致的系统降频，硬件性能释放正常。${NC}"
    fi
fi

# ============ KERNEL ERROR ANALYSIS ============
log ""
log "${CYAN}=== 内核底层警告分析 ===${NC}"
if [ -f "$KERNEL_LOG" ] && [ $(wc -l < "$KERNEL_LOG") -gt 1 ]; then
    error_count=$(wc -l < "$KERNEL_LOG")
    log "${RED}检测到 $error_count 条关键内核警告，这些是底层性能问题的直接证据:${NC}"
    
    if grep -qi "droop" "$KERNEL_LOG"; then log "${RED}  - 电压降 (voltage droop) 事件 -> 电池供电不足导致硬件强制降频。${NC}"; fi
    if grep -qi "thermal" "$KERNEL_LOG"; then log "${YELLOW}  - SMC 热管理事件 (thermal) -> 系统触发过热保护。${NC}"; fi
    if grep -qi "overcurrent" "$KERNEL_LOG"; then log "${RED}  - 过流保护 (overcurrent) -> 主板供电模块保护。${NC}"; fi
else
    log "${GREEN}未检测到内核硬件警告。${NC}"
fi

# ============ FINAL SUMMARY ============
header "5. 诊断总结"

log "测试持续时间：${DURATION} 秒 ($((DURATION/60)) 分 $((DURATION%60)) 秒)"

issues=0
[ $VOLTAGE_WARNING -eq 1 ] && issues=$((issues+1))
[ $THERMAL_WARNING -eq 1 ] && issues=$((issues+1))
[ $KERNEL_TASK_WARNING -eq 1 ] && issues=$((issues+1))
[ -f "$KERNEL_LOG" ] && [ $(wc -l < "$KERNEL_LOG") -gt 1 ] && issues=$((issues+1))

log ""
if [ $issues -eq 0 ]; then
    log "${GREEN}======================================================${NC}"
    log "${GREEN}  系统通过压力测试，未发现导致性能卡顿的硬件根源。${NC}"
    log "${GREEN}======================================================${NC}"
else
    log "${RED}======================================================${NC}"
    log "${RED}  诊断到 $issues 个严重的硬件级性能瓶颈根源！${NC}"
    log "${RED}  修复建议：${NC}"
    [ $KERNEL_TASK_WARNING -eq 1 ] || [ $THERMAL_WARNING -eq 1 ] || [ "${max_c_t:-0}" -ge 95 ] 2>/dev/null && log "${RED}  1. 散热系统瘫痪：必须清灰并重新涂抹高性能 CPU/GPU 导热硅脂 (如 7950 相变片)。${NC}"
    if [ $VOLTAGE_WARNING -eq 1 ] || [[ "$bat_cond" == "Service Recommended" ]] || [[ "$bat_cond" == "Replace Now" ]]; then
        log "${RED}  2. 电池供电失效：电池老化严重内阻大，满载供电不足会触发硬件级锁死 (频率掉0)。必须更换新电池！${NC}"
        log "${RED}  => 【关键结论】：单纯只修散热或只换电池，依然会因为另一半瓶颈触发卡死！务必“双管齐下”维修！${NC}"
    fi
    log "${RED}======================================================${NC}"
fi

log ""
log "${BLUE}诊断数据报告生成于:${NC} $REPORT_DIR (系统重启后清理)"
