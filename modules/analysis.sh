#!/bin/bash

# ==============================================================================
# 分析诊断模块 - 数据分析、问题诊断、报告生成
# ==============================================================================

analyze_power_data() {
    log ""
    log "${CYAN}=== 功耗与电源诊断 ===${NC}"
    if [ -f "$POWER_LOG" ] && [ $(wc -l < "$POWER_LOG") -gt 1 ]; then
        # Skip header and analyze power data
        max_cpu_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -E '^[0-9.]+$' | sort -n | tail -1)
        min_cpu_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -E '^[0-9.]+$' | sort -n | head -1)
        max_gpu_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f3 | grep -E '^[0-9.]+$' | sort -n | tail -1)
        max_mem_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f4 | grep -E '^[0-9.]+$' | sort -n | tail -1)

        # Calculate average power consumption
        avg_cpu_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f2 | grep -E '^[0-9.]+$' | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count}')
        avg_gpu_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f3 | grep -E '^[0-9.]+$' | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count}')
        avg_mem_power=$(tail -n +2 "$POWER_LOG" | cut -d',' -f4 | grep -E '^[0-9.]+$' | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count}')

        log "CPU 峰值功耗：${max_cpu_power:-N/A}W"
        log "CPU 平均功耗：${avg_cpu_power:-N/A}W"
        log "GPU 峰值功耗：${max_gpu_power:-N/A}W"
        log "GPU 平均功耗：${avg_gpu_power:-N/A}W"
        log "内存峰值功耗：${max_mem_power:-N/A}W"
        log "内存平均功耗：${avg_mem_power:-N/A}W"

        # Power analysis and diagnostics
        if [ -n "$max_cpu_power" ] && echo "$max_cpu_power" | grep -qE '^[0-9.]+$'; then
            if (( $(echo "$max_cpu_power > 45" | bc -l) )); then
                log "${RED}>>> 诊断：CPU 峰值功耗超过 45W (${max_cpu_power}W)，表明 CPU 在高负载下全力运行。${NC}"
            elif (( $(echo "$max_cpu_power > 25" | bc -l) )); then
                log "${YELLOW}>>> 诊断：CPU 功耗偏高 (${max_cpu_power}W)，可能正在处理高负载任务。${NC}"
            else
                log "${GREEN}>>> 诊断：CPU 功耗正常 (${max_cpu_power}W)。${NC}"
            fi
        fi

        if [ -n "$max_gpu_power" ] && echo "$max_gpu_power" | grep -qE '^[0-9.]+$'; then
            if (( $(echo "$max_gpu_power > 20" | bc -l) )); then
                log "${RED}>>> 诊断：GPU 峰值功耗超过 20W (${max_gpu_power}W)，GPU 正在高负载运行。${NC}"
            elif (( $(echo "$max_gpu_power > 5" | bc -l) )); then
                log "${YELLOW}>>> 诊断：GPU 功耗较高 (${max_gpu_power}W)，可能正在运行图形密集型任务。${NC}"
            else
                log "${GREEN}>>> 诊断：GPU 功耗正常 (${max_gpu_power}W)。${NC}"
            fi
        fi

        # Total system power estimation
        if [ -n "$max_cpu_power" ] && [ -n "$max_gpu_power" ] && echo "$max_cpu_power" | grep -qE '^[0-9.]+$' && echo "$max_gpu_power" | grep -qE '^[0-9.]+$'; then
            total_power=$(echo "$max_cpu_power + $max_gpu_power" | bc -l 2>/dev/null || echo "0")
            if (( $(echo "$total_power > 65" | bc -l) )); then
                log "${RED}>>> 系统总功耗过高 (${total_power}W)，可能导致严重发热和降频。${NC}"
            fi
        fi
    else
        log "${YELLOW}未获取到足够的功耗数据进行分析。${NC}"
    fi
}

analyze_voltage_data() {
    log "${CYAN}=== 电源与电压诊断 ===${NC}"
    if [ -f "$VOLTAGE_LOG" ] && [ $(wc -l < "$VOLTAGE_LOG") -gt 1 ]; then
        # Skip header and get only numeric values
        max_v=$(tail -n +2 "$VOLTAGE_LOG" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | tail -1)
        min_v=$(tail -n +2 "$VOLTAGE_LOG" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | head -1)

        if [ -n "$max_v" ] && [ -n "$min_v" ] && [ "$max_v" -ge 8000 ] 2>/dev/null && [ "$min_v" -ge 8000 ] 2>/dev/null; then
            drop=$((max_v - min_v))
            log "最高电压：${max_v}mV"
            log "最低电压：${min_v}mV"
            log "最大压降：${drop}mV"

            if [ -n "$drop" ] && [ "$drop" -gt "$VOLTAGE_DROP_THRESHOLD" ] 2>/dev/null; then
                if [ "$is_new_battery" -eq 1 ]; then
                    log "${RED}>>> 诊断：新电池情况下仍出现严重压降 (${drop}mV)，可能电源适配器功率不足或主板供电问题。${NC}"
                else
                    log "${RED}>>> 诊断：电池老化严重。满载时电压降过大 (${drop}mV)，这会触发硬件级降频 (PROCHOT) 以防断电。${NC}"
                fi
                VOLTAGE_WARNING=1
            else
                log "${GREEN}>>> 供电稳定。${NC}"
            fi
        else
            log "无法获取有效的电压数据进行分析。"
        fi
    fi
}

analyze_thermal_data() {
    log ""
    log "${CYAN}=== 降频与温度诊断 ===${NC}"
    if [ -f "$THERMAL_LOG" ] && [ $(wc -l < "$THERMAL_LOG") -gt 1 ]; then
        # Skip header and get only numeric values with proper validation
        max_c_t=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f2 | grep -E '^[0-9]+$' | sort -n | tail -1)
        min_freq=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f6 | grep -E '^[0-9]+$' | sort -n | head -1)
        max_ktask_raw=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f7 | grep -E '^[0-9.]+$' | sort -n | tail -1)
        max_ktask=$(echo "${max_ktask_raw:-0}" | awk '{print int($1)}')
        min_clim=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f8 | grep -E '^[0-9]+$' | sort -n | head -1)

        max_plimit=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f9 | grep -E '^[0-9.]+$' | sort -n | tail -1)
        sum_prochot=$(tail -n +2 "$THERMAL_LOG" | cut -d',' -f10 | grep -E '^[0-9]+$' | awk '{sum+=$1} END {print sum+0}')

        # Validate data before displaying
        if [ -z "$max_c_t" ] || ! echo "$max_c_t" | grep -qE '^[0-9]+$'; then max_c_t="N/A"; fi
        if [ -z "$min_freq" ] || ! echo "$min_freq" | grep -qE '^[0-9]+$'; then min_freq="N/A"; fi
        if [ -z "$min_clim" ] || ! echo "$min_clim" | grep -qE '^[0-9]+$'; then min_clim="100"; fi
        if [ -z "$max_ktask" ] || ! echo "$max_ktask" | grep -qE '^[0-9]+$'; then max_ktask="0"; fi
        if [ -z "$max_plimit" ] || ! echo "$max_plimit" | grep -qE '^[0-9.]+$'; then max_plimit="0.00"; fi
        if [ -z "$sum_prochot" ] || ! echo "$sum_prochot" | grep -qE '^[0-9]+$'; then sum_prochot="0"; fi

        log "CPU 峰值温度：${max_c_t}°C"
        log "CPU 最低频率：${min_freq}MHz"
        log "系统最严重限速：${min_clim}%"
        log "kernel_task 最高占用：${max_ktask}%"
        log "CPU 最大 Plimit (功耗锁)：${max_plimit}"
        log "PROCHOT 触发总次数：${sum_prochot}"

        # Analyze Throttling Root Cause
        log ""
        log "${YELLOW}--- 性能瓶颈根因分析 (基于底层硬件传感器实证) ---${NC}"

        throttled=0

        max_plimit_num=$(echo "$max_plimit" | awk '{print int($1)}')
        if [ -n "$max_plimit" ] && [ "$max_plimit_num" -gt 10 ]; then
            if [ "$is_new_battery" -eq 1 ]; then
                log "${RED}【铁证 1】 捕捉到 CPU Plimit 高达 ${max_plimit}%！新电池情况下仍出现严重供电限制，表明电源适配器或主板供电系统存在问题！${NC}"
            else
                log "${RED}【铁证 1】 捕捉到 CPU Plimit 高达 ${max_plimit}%！电池老化无法提供足够电流，在物理层面触发了 CPU 功耗限制！${NC}"
            fi
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
}

analyze_disk_io_data() {
    log ""
    log "${CYAN}=== 硬盘 I/O 性能诊断 ===${NC}"
    if [ -f "$DISK_LOG" ] && [ $(wc -l < "$DISK_LOG") -gt 1 ]; then
        # Skip header and get only numeric values
        avg_mb=$(tail -n +2 "$DISK_LOG" | cut -d',' -f4 | grep -E '^[0-9.]+$' | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count}')
        max_mb=$(tail -n +2 "$DISK_LOG" | cut -d',' -f4 | grep -E '^[0-9.]+$' | sort -n | tail -1)
        avg_tps=$(tail -n +2 "$DISK_LOG" | cut -d',' -f3 | grep -E '^[0-9.]+$' | awk '{sum+=$1; count++} END {if(count>0) printf "%.0f", sum/count}')
        max_tps=$(tail -n +2 "$DISK_LOG" | cut -d',' -f3 | grep -E '^[0-9.]+$' | sort -n | tail -1)

        # Validate data
        if [ -z "$avg_mb" ] || ! echo "$avg_mb" | grep -qE '^[0-9.]+$'; then avg_mb="0"; fi
        if [ -z "$max_mb" ] || ! echo "$max_mb" | grep -qE '^[0-9.]+$'; then max_mb="0"; fi
        if [ -z "$avg_tps" ] || ! echo "$avg_tps" | grep -qE '^[0-9.]+$'; then avg_tps="0"; fi
        if [ -z "$max_tps" ] || ! echo "$max_tps" | grep -qE '^[0-9.]+$'; then max_tps="0"; fi

        log "平均吞吐量：${avg_mb} MB/s"
        log "峰值吞吐量：${max_mb} MB/s"
        log "平均 IOPS：${avg_tps}"
        log "峰值 IOPS：${max_tps}"

        is_low=0
        is_med=0
        if [ "$(echo "$avg_mb > 0 && $avg_mb < 50" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
            is_low=1
        elif [ "$(echo "$avg_mb >= 50 && $avg_mb < 200" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
            is_med=1
        fi

        if [ "$is_low" -eq 1 ]; then
            log "${RED}>>> 诊断：硬盘 I/O 性能极低 (${avg_mb} MB/s)。这会导致严重的系统卡顿，尤其是内存不足引发频繁 SWAP 时。建议检查硬盘健康状态或更换高速 SSD。${NC}"
        elif [ "$is_med" -eq 1 ]; then
            log "${YELLOW}>>> 诊断：硬盘 I/O 性能偏低 (${avg_mb} MB/s)。对于现代 macOS 在重度读写场景下可能存在瓶颈。${NC}"
        else
            log "${GREEN}>>> 诊断：硬盘 I/O 性能正常 (${avg_mb} MB/s)。${NC}"
        fi
    else
        log "${YELLOW}未获取到足够的硬盘 I/O 数据。${NC}"
    fi
}

analyze_kernel_errors() {
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
}