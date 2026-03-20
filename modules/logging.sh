#!/bin/bash

# ==============================================================================
# 日志和输出模块 - 处理日志记录、颜色输出、报告生成
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

header() {
    log ""
    log "${CYAN}============================================================${NC}"
    log "${CYAN}$1${NC}"
    log "${CYAN}============================================================${NC}"
}

print_system_info() {
    log "${CYAN}=== 系统信息 ===${NC}"
    cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
    cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "Unknown")
    mem_size=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.1f GB", $1/1024/1024/1024}' 2>/dev/null || echo "Unknown")
    macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "Unknown")
    gpu_info=$(system_profiler SPDisplaysDataType 2>/dev/null | awk '/Chipset Model/ {print substr($0, index($0, $3))}' | paste -sd ", " - 2>/dev/null || echo "Unknown")

    log "CPU: $cpu_model"
    log "核心数：$cpu_cores"
    log "内存：$mem_size"
    log "macOS: $macos_ver"
    log "GPU: $gpu_info"
    log ""
}

print_final_summary() {
    log ""
    log "测试持续时间：${DURATION} 秒 ($((DURATION/60)) 分 $((DURATION%60)) 秒)"

    issues=0
    [ $VOLTAGE_WARNING -eq 1 ] && issues=$((issues+1))
    [ $THERMAL_WARNING -eq 1 ] && issues=$((issues+1))
    [ $KERNEL_TASK_WARNING -eq 1 ] && issues=$((issues+1))
    [ -f "$KERNEL_LOG" ] && [ $(wc -l < "$KERNEL_LOG") -gt 1 ] && issues=$((issues+1))
    [ "${is_low:-0}" -eq 1 ] && issues=$((issues+1))

    log ""
    if [ $issues -eq 0 ]; then
        log "${GREEN}======================================================${NC}"
        log "${GREEN}  系统通过压力测试，未发现导致性能卡顿的硬件根源。${NC}"
        log "${GREEN}======================================================${NC}"
    else
        log "${RED}======================================================${NC}"
        log "${RED}  诊断到 $issues 个严重的硬件级性能瓶颈根源！${NC}"
        log "${RED}  修复建议：${NC}"
        [ $KERNEL_TASK_WARNING -eq 1 ] || [ $THERMAL_WARNING -eq 1 ] || [ "${max_c_t:-0}" -ge 95 ] 2>/dev/null && log "${RED}  - 散热系统瘫痪：必须清灰并重新涂抹高性能 CPU/GPU 导热硅脂 (如 7950 相变片)。${NC}"
        if [ $VOLTAGE_WARNING -eq 1 ]; then
            if [ "$is_new_battery" -eq 1 ]; then
                log "${RED}  - 电源适配器问题：新电池情况下仍出现供电限制，建议检查电源适配器功率是否足够或尝试更高功率的适配器！${NC}"
            elif [[ "$bat_cond" == "Service Recommended" ]] || [[ "$bat_cond" == "Replace Now" ]] || [[ "$bat_cond" == "Poor" ]]; then
                log "${RED}  - 电池供电失效：电池老化严重内阻大，满载供电不足会触发硬件级锁死 (频率掉0)。必须更换新电池！${NC}"
            else
                log "${RED}  - 电池供电问题：检测到供电限制，可能电池健康度下降或电源适配器功率不足！${NC}"
            fi
        elif [[ "$bat_cond" == "Service Recommended" ]] || [[ "$bat_cond" == "Replace Now" ]] || [[ "$bat_cond" == "Poor" ]]; then
            log "${RED}  - 电池需要更换：电池状态为 $bat_cond，建议更换新电池以确保稳定供电！${NC}"
        fi
        if [ "${is_low:-0}" -eq 1 ]; then
            log "${RED}  - 硬盘读写失效：系统检测到极端缓慢的 I/O 速度 (${avg_mb:-0} MB/s)，可能是硬盘寿命濒危或严重降速，建议立即备份数据并更换高速 SSD。${NC}"
        fi
        if [ $VOLTAGE_WARNING -eq 1 ] && ( [ $KERNEL_TASK_WARNING -eq 1 ] || [ $THERMAL_WARNING -eq 1 ] ); then
            log "${RED}  => 【关键结论】：单纯只修散热或只换电池，依然会因为另一半瓶颈触发卡死！务必“双管齐下”维修！${NC}"
        fi
        log "${RED}======================================================${NC}"
    fi

    log ""
    log "${BLUE}诊断数据报告生成于:${NC} $REPORT_DIR (系统重启后清理)"
    log ""
    log "${CYAN}使用方法：${NC}"
    log "  sudo ./stress_no_gltest.sh                    # 默认设置"
    log "  sudo ./stress_no_gltest.sh -d 600 -s 1       # 自定义时长和采样间隔"
    log "  sudo ./stress_no_gltest.sh --duration 1200   # 20分钟测试"
}