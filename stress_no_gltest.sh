#!/bin/bash

# ==============================================================================
# macOS Intel CPU + GPU 压力测试及性能诊断工具 (NO GLTEST VERSION) - Modular v8.0
# 模块化架构 - 各功能分离到独立文件，便于维护和扩展
# ==============================================================================

# Source all module files
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/modules/config.sh"
source "$SCRIPT_DIR/modules/logging.sh"
source "$SCRIPT_DIR/modules/system_info.sh"
source "$SCRIPT_DIR/modules/monitoring.sh"
source "$SCRIPT_DIR/modules/monitoring_nonroot.sh"
source "$SCRIPT_DIR/modules/monitoring_alt.sh"
source "$SCRIPT_DIR/modules/stress_tests.sh"
source "$SCRIPT_DIR/modules/analysis.sh"
source "$SCRIPT_DIR/modules/charting.sh"

# Initialize global variables
EARLY_STOP=0

# Parse command line arguments
parse_arguments "$@"

# Initialize report directory and log files
initialize_report_dir

# Cleanup function with better error handling
cleanup() {
    log "${YELLOW}[清理] 停止所有负载进程...${NC}"

    # Kill all stress processes
    pkill -f openssl 2>/dev/null || true
    pkill -f dd 2>/dev/null || true
    pkill -f qlmanage 2>/dev/null || true
    pkill -f sips 2>/dev/null || true
    pkill -f iostat 2>/dev/null || true
    pkill -f gpu_stress_bin 2>/dev/null || true
    pkill -f "bc -l" 2>/dev/null || true
    pkill -f "yes >" 2>/dev/null || true

    # Clean up temporary files
    rm -f /tmp/stress_*.tiff /tmp/stress_*.png /tmp/gpu_stress_* /tmp/gpu_base_*.ppm /tmp/gpu_resize_* /tmp/*_resize_*.png 2>/dev/null
    rm -rf /tmp/ql_* /tmp/ql_tmp* /tmp/ql_r* /tmp/ql_t* /tmp/mem_stress_* /tmp/stress_cpu_run /tmp/stress_gpu_run /tmp/stress_disk_run /tmp/disk_stress_test 2>/dev/null
    rm -f /tmp/gpu_stress_bin 2>/dev/null
    rm -f /tmp/stress_early_stop.flag 2>/dev/null

    # Kill monitoring processes
    pkill -f powermetrics 2>/dev/null || true
    pkill -f ioreg 2>/dev/null || true
    pkill -f "vm_stat" 2>/dev/null || true
    pkill -f "iostat" 2>/dev/null || true
    pkill -f "log stream" 2>/dev/null || true

    # Wait for background processes to finish
    wait 2>/dev/null || true
}

handle_interrupt() {
    log ""
    log "${RED}======================================================${NC}"
    log "${RED}  >>> 检测到提前终止信号 (Ctrl+C) <<<${NC}"
    log "${RED}  正在安全停止所有负载测试，并生成当前收集到的诊断报告...${NC}"
    log "${RED}======================================================${NC}"
    EARLY_STOP=1
    touch /tmp/stress_early_stop.flag
    # Immediately stop all stress processes
    cleanup
    # Exit gracefully
    exit 0
}

trap cleanup EXIT
trap handle_interrupt INT TERM

clear
log "${BLUE}========================================${NC}"
log "${BLUE}  macOS Intel 性能诊断与压力测试工具${NC}"
log "${BLUE}  v8.0 (模块化架构 - 更好的维护性)${NC}"
log "${BLUE}========================================${NC}"
log ""
log "输出目录：$REPORT_DIR (测试结束后自动清理)"
log ""

print_system_info

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
log "  5) 仅测试 硬盘 IO (~5分钟)"
log "  6) 极限全系统测试 (CPU+GPU+内存+硬盘) (~5分钟)"
read -p "请输入选项 [1-6] 并按回车: " choice

case $choice in
    1) TEST_MODE="ALL" ;;
    2) TEST_MODE="CPU" ;;
    3) TEST_MODE="GPU" ;;
    4) TEST_MODE="DUAL" ;;
    5) TEST_MODE="DISK" ;;
    6) TEST_MODE="FULL" ;;
    *) log "${RED}无效选项，退出。${NC}"; exit 0 ;;
esac

log ""
log "${YELLOW}5 秒后开始测试，请保存工作...${NC}"
sleep 5

START_TIME=$(date +%s)

header "1. 基线检查"

# Battery check with multi-source validation and better error handling
log "${CYAN}=== 电池状态 ===${NC}"

if get_battery_info; then
    get_battery_condition
    log "${BLUE}电池健康度:${NC} ${health_pct}%"
    log "${BLUE}电池状态:${NC} $bat_cond"
    log "${BLUE}循环次数:${NC} ${bat_cycle:-0}"
else
    log "${RED}✗ 无法读取电池信息${NC}"
    health_pct=0
    bat_cond="Unknown"
    bat_cycle=0
fi

# Smart battery warning logic - don't warn for new batteries
is_new_battery=0
if [ "$health_pct" -ge 95 ] && [ "${bat_cycle:-0}" -lt 50 ]; then
    is_new_battery=1
fi

if [ "$is_new_battery" -eq 0 ] && ([[ "$bat_cond" == "Service Recommended" ]] || [[ "$bat_cond" == "Replace Now" ]] || [[ "$bat_cond" == "Poor" ]]); then
    log "${RED}>>> 警告：电池需要更换！电池老化是导致 CPU 严重降频和突发关机的主要原因！${NC}"
fi

check_power_status
get_initial_voltage

header "2. 启动诊断监控"

# Initialize CSV logs
initialize_csv_logs

# Start all monitoring processes based on permissions
if [ "$EUID" -eq 0 ]; then
    # Root mode - use hybrid monitoring (powermetrics + ioreg backup)
    log "${YELLOW}[提示] Root模式，使用混合监控算法${NC}"
    start_combined_monitoring
else
    # Non-root mode - use ioreg-based monitoring
    log "${YELLOW}[提示] 非Root模式，使用ioreg监控算法${NC}"
    start_voltage_monitor
    start_thermal_monitor_alt
    start_power_monitor_alt
    start_disk_io_monitor
fi

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
    PHASE_START_TIME=$(date +%s)
    CURRENT_PHASE="CPU"
else
    TOTAL_DURATION=$PHASE_DURATION
    log "总测试时长：$((TOTAL_DURATION/60)) 分钟"
    PHASE_START_TIME=$(date +%s)
    if [ "$TEST_MODE" == "CPU" ]; then
        log "模式: 仅 CPU 单烤测试"
        start_cpu_stress
        CURRENT_PHASE="CPU"
    fi
    if [ "$TEST_MODE" == "GPU" ]; then
        log "模式: 仅 GPU 单烤测试"
        start_gpu_stress
        CURRENT_PHASE="GPU"
    fi
    if [ "$TEST_MODE" == "DUAL" ]; then
        log "模式: 仅 极限满载双烤测试"
        start_cpu_stress
        start_gpu_stress
        start_mem_stress
        CURRENT_PHASE="DUAL"
    fi
    if [ "$TEST_MODE" == "DISK" ]; then
        log "模式: 仅 硬盘 IO 测试"
        start_disk_stress
        CURRENT_PHASE="DISK"
    fi
    if [ "$TEST_MODE" == "FULL" ]; then
        log "模式: 极限全系统测试 (CPU+GPU+内存+硬盘)"
        start_cpu_stress
        start_gpu_stress
        start_mem_stress
        start_disk_stress
        CURRENT_PHASE="FULL"
    fi
    log ""
fi

# Use actual time tracking instead of loop counter
ELAPSED_TIME=0
LAST_UPDATE=0
while [ $ELAPSED_TIME -lt $TOTAL_DURATION ] && [ $EARLY_STOP -eq 0 ]; do
    sleep 1
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

    if [ "$TEST_MODE" == "ALL" ]; then
        # Phase state switching control based on actual elapsed time
        if [ "$CURRENT_PHASE" = "CPU" ] && [ $ELAPSED_TIME -ge $PHASE_DURATION ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入冷却暂停：停止负载，等待 3 分钟以恢复基线温度${NC}"
            log "${CYAN}======================================================${NC}"
            stop_cpu_stress
            wait $CPU_PID 2>/dev/null
            CURRENT_PHASE="COOLING1"
            COOLING_START_TIME=$CURRENT_TIME
        elif [ "$CURRENT_PHASE" = "COOLING1" ] && [ $ELAPSED_TIME -ge $((PHASE_DURATION + PAUSE_DURATION)) ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入阶段 2：纯 GPU 单烤压力测试${NC}"
            log "${CYAN}======================================================${NC}"
            start_gpu_stress
            CURRENT_PHASE="GPU"
        elif [ "$CURRENT_PHASE" = "GPU" ] && [ $ELAPSED_TIME -ge $((PHASE_DURATION * 2 + PAUSE_DURATION)) ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入冷却暂停：停止负载，等待 3 分钟以恢复基线温度${NC}"
            log "${CYAN}======================================================${NC}"
            stop_gpu_stress
            wait $GPU_PID 2>/dev/null
            CURRENT_PHASE="COOLING2"
            COOLING_START_TIME=$CURRENT_TIME
        elif [ "$CURRENT_PHASE" = "COOLING2" ] && [ $ELAPSED_TIME -ge $((PHASE_DURATION * 2 + PAUSE_DURATION * 2)) ]; then
            log ""
            log "${CYAN}======================================================${NC}"
            log "${CYAN}  ▶ 进入阶段 3：极限满载 (CPU + GPU 双烤)${NC}"
            log "${CYAN}======================================================${NC}"
            start_cpu_stress
            start_gpu_stress
            start_mem_stress
            CURRENT_PHASE="DUAL"
        fi
    fi

    if [ $((ELAPSED_TIME % 10)) -eq 0 ] && [ $ELAPSED_TIME -ne $LAST_UPDATE ]; then
        LAST_UPDATE=$ELAPSED_TIME
        elapsed=$((ELAPSED_TIME/60))
        remaining=$(((TOTAL_DURATION-ELAPSED_TIME)/60))

        # Determine Current Phase Name
        if [ "$TEST_MODE" == "ALL" ]; then
            if [ $ELAPSED_TIME -le $PHASE_DURATION ]; then
                current_phase="阶段1: CPU单烤"
            elif [ $ELAPSED_TIME -le $((PHASE_DURATION + PAUSE_DURATION)) ]; then
                current_phase="冷却恢复中 (准备GPU单烤)"
            elif [ $ELAPSED_TIME -le $((PHASE_DURATION * 2 + PAUSE_DURATION)) ]; then
                current_phase="阶段2: GPU单烤"
            elif [ $ELAPSED_TIME -le $((PHASE_DURATION * 2 + PAUSE_DURATION * 2)) ]; then
                current_phase="冷却恢复中 (准备极限双烤)"
            else
                current_phase="阶段3: 极限双烤"
            fi
        else
            if [ "$TEST_MODE" == "CPU" ]; then current_phase="纯CPU单烤"; fi
            if [ "$TEST_MODE" == "GPU" ]; then current_phase="纯GPU单烤"; fi
            if [ "$TEST_MODE" == "DUAL" ]; then current_phase="极限双烤"; fi
            if [ "$TEST_MODE" == "DISK" ]; then current_phase="硬盘IO测试"; fi
            if [ "$TEST_MODE" == "FULL" ]; then current_phase="全系统极限压力"; fi
        fi

        # Retrieve latest telemetry
        if [ -f "$THERMAL_LOG" ]; then
            latest_data=$(tail -1 "$THERMAL_LOG" 2>/dev/null)
            if [ -n "$latest_data" ]; then
                # Skip header row - check if first field contains letters (timestamp should be HH:MM:SS)
                if echo "$latest_data" | grep -qE '^[A-Za-z]'; then
                    # This is a header row, skip processing
                    continue
                fi

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

                # Validate that we have numeric data before processing
                if ! echo "$c_t" | grep -qE '^[0-9]+$' || ! echo "$c_freq" | grep -qE '^[0-9]+$'; then
                    # Skip non-numeric data
                    continue
                fi

                log "${BLUE}[${elapsed}分] 剩余 ${remaining}分 | ${current_phase}：${NC}"

                log_str="  CPU: 温度 ${c_t}°C | 频率 ${c_freq}MHz | Plimit ${c_plimit} | 限速器 ${c_lim}% | Kernel_Task占用 ${ktask}%"
                if [ -n "$g_t" ] && [ "$g_t" != "0" ] && echo "$g_t" | grep -qE '^[0-9]+$' && [ "$g_t" -gt 0 ]; then
                    log_str="$log_str | GPU: ${g_t}°C (负载 ${g_act}%) | 风扇: ${f_rpm} RPM"
                else
                    log_str="$log_str | 风扇: ${f_rpm} RPM"
                fi
                log "$log_str"

                # Diagnose Hardware Plimit (Battery/Power Delivery) - Plimit is percentage (0.00-100.00)
                c_plimit_num=$(echo "$c_plimit" | awk '{print int($1)}')
                if [ -n "$c_plimit" ] && [ "$c_plimit_num" -gt 10 ]; then
                    if [ "$is_new_battery" -eq 1 ]; then
                        log "${RED}  >>> [供电限制警告] CPU Plimit 高达 ${c_plimit}%！新电池配合高功率电源适配器仍出现供电限制，可能电源适配器功率不足或主板供电问题！${NC}"
                    else
                        log "${RED}  >>> [供电限制警告] CPU Plimit 高达 ${c_plimit}%！电池老化或电源适配器无法提供足够电流，触发硬件级功耗限制！${NC}"
                    fi
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

                # Enhanced temperature warnings with proper thresholds
                if [ -n "$c_t" ] && [ "$c_t" -ge "$TEMP_CRIT" ] 2>/dev/null; then
                    log "${RED}  >>> [临界过热警告] CPU 温度达到临界值：${c_t}°C (阈值: ${TEMP_CRIT}°C)${NC}"
                    THERMAL_WARNING=1
                elif [ -n "$c_t" ] && [ "$c_t" -ge "$TEMP_WARN" ] 2>/dev/null; then
                    log "${YELLOW}  >>> [高温警告] CPU 温度偏高：${c_t}°C (警告阈值: ${TEMP_WARN}°C)${NC}"
                fi

                # GPU temperature warnings
                if [ -n "$g_t" ] && [ "$g_t" -ge "$TEMP_CRIT" ] 2>/dev/null; then
                    log "${RED}  >>> [临界过热警告] GPU 温度达到临界值：${g_t}°C (阈值: ${TEMP_CRIT}°C)${NC}"
                    THERMAL_WARNING=1
                elif [ -n "$g_t" ] && [ "$g_t" -ge "$TEMP_WARN" ] 2>/dev/null; then
                    log "${YELLOW}  >>> [高温警告] GPU 温度偏高：${g_t}°C (警告阈值: ${TEMP_WARN}°C)${NC}"
                fi
            fi
        fi

        # Enhanced voltage check with new battery awareness
        if [ -n "$init_vol" ]; then
            cur_vol=$(tail -1 "$VOLTAGE_LOG" 2>/dev/null | cut -d',' -f2)
            if [ -n "$cur_vol" ] && [ "$cur_vol" -gt 8000 ] 2>/dev/null && [ "$cur_vol" -lt 18000 ] 2>/dev/null; then
                if [ "$init_vol" -gt "$cur_vol" ]; then drop=$((init_vol - cur_vol)); else drop=0; fi
                if [ -n "$drop" ] && [ "$drop" -gt "$VOLTAGE_DROP_THRESHOLD" ] 2>/dev/null && [ $VOLTAGE_WARNING -eq 0 ]; then
                    if [ "$is_new_battery" -eq 1 ]; then
                        log "${RED}  >>> [电源适配器警告] 电压瞬降过大：${drop}mV (新电池情况下仍出现压降，可能电源适配器功率不足)${NC}"
                    else
                        log "${RED}  >>> [电池警告] 电压瞬降过大：${drop}mV (供电不足导致强制降频)${NC}"
                    fi
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
stop_all_monitors
cleanup
sleep 2

# Run analysis modules
analyze_voltage_data
analyze_power_data
analyze_thermal_data
analyze_disk_io_data
analyze_kernel_errors

# Generate charts
header "5. 生成图表报告"
generate_all_charts

# Final summary
header "6. 诊断总结"
print_final_summary