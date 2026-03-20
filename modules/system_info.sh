#!/bin/bash

# ==============================================================================
# 系统信息模块 - 获取CPU、GPU、内存、电池等系统信息
# ==============================================================================

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

# Try multiple data sources for battery information
get_battery_info() {
    # Method 1: Direct MaxCapacity and DesignCapacity from top level (most reliable)
    max_cap=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"MaxCapacity"' | head -1 | grep -oE '[0-9]+$')
    design_cap=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"DesignCapacity"' | head -1 | grep -oE '[0-9]+$')
    bat_cycle=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"CycleCount"' | head -1 | grep -oE '[0-9]+$')

    if [ -n "$max_cap" ] && [ -n "$design_cap" ] && [ "$design_cap" -gt 0 ]; then
        health_pct=$((max_cap * 100 / design_cap))
        return 0
    fi

    # Method 2: LegacyBatteryInfo as fallback
    bat_legacy=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"LegacyBatteryInfo"' | head -1)
    if [ -n "$bat_legacy" ]; then
        bat_cycle=$(echo "$bat_legacy" | grep -oE '"Cycle Count"=[0-9]+' | grep -oE '[0-9]+')

        # Extract capacity from LegacyBatteryInfo if available
        legacy_cap=$(echo "$bat_legacy" | grep -oE '"Capacity"=[0-9]+' | grep -oE '[0-9]+')
        if [ -n "$legacy_cap" ] && [ -n "$design_cap" ] && [ "$design_cap" -gt 0 ]; then
            health_pct=$((legacy_cap * 100 / design_cap))
            return 0
        fi
    fi

    # Method 3: FccComp from BatteryData as another fallback
    if [ -z "$health_pct" ] || [ "$health_pct" -eq 0 ]; then
        bat_data=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"BatteryData"' | head -1)
        if [ -n "$bat_data" ]; then
            fcc_comp=$(echo "$bat_data" | grep -oE '"FccComp[12]"=[0-9]+' | head -1 | grep -oE '[0-9]+$')
            design_cap=$(echo "$bat_data" | grep -oE '"DesignCapacity"=[0-9]+' | grep -oE '[0-9]+')
            bat_cycle=$(echo "$bat_data" | grep -oE '"CycleCount"=[0-9]+' | grep -oE '[0-9]+')

            if [ -n "$fcc_comp" ] && [ -n "$design_cap" ] && [ "$design_cap" -gt 0 ]; then
                health_pct=$((fcc_comp * 100 / design_cap))
                return 0
            fi
        fi
    fi

    # Method 4: system_profiler fallback
    if [ -z "$health_pct" ] || [ "$health_pct" -eq 0 ]; then
        sys_bat_info=$(system_profiler SPPowerDataType 2>/dev/null)
        if [ -n "$sys_bat_info" ]; then
            max_cap=$(echo "$sys_bat_info" | grep -i "Full Charge Capacity" | grep -oE '[0-9]+' | head -1)
            design_cap=$(echo "$sys_bat_info" | grep -i "Design Capacity" | grep -oE '[0-9]+' | head -1)
            bat_cycle=$(echo "$sys_bat_info" | grep -i "Cycle Count" | grep -oE '[0-9]+' | head -1)

            if [ -n "$max_cap" ] && [ -n "$design_cap" ] && [ "$design_cap" -gt 0 ]; then
                health_pct=$((max_cap * 100 / design_cap))
                return 0
            fi
        fi
    fi

    # If all methods fail
    health_pct=0
    bat_cycle=0
    return 1
}

get_battery_condition() {
    # Determine battery condition
    if [ "$health_pct" -ge 95 ] && [ "${bat_cycle:-0}" -lt 50 ]; then
        bat_cond="New Battery"
        is_new_battery=1
        log "${GREEN}>>> 检测到新电池（健康度>95%，循环<50）${NC}"
    elif [ "$health_pct" -ge 80 ]; then
        bat_cond="Good"
        is_new_battery=0
    elif [ "$health_pct" -ge 50 ]; then
        bat_cond="Fair"
        is_new_battery=0
    elif [ "$health_pct" -ge 30 ]; then
        bat_cond="Poor"
        is_new_battery=0
    else
        bat_cond="Service Recommended"
        is_new_battery=0
    fi
}

check_power_status() {
    # Method 1: Use ioreg ExternalConnected (most reliable)
    external_connected=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"ExternalConnected"' | awk '{print $NF}' | tr -d '\r\n')

    if [ "$external_connected" = "Yes" ]; then
        ac_power="AC attached"
    else
        # Method 2: Fallback to pmset
        if pmset -g batt 2>/dev/null | grep -q "AC attached"; then
            ac_power="AC attached"
        else
            ac_power="On Battery"
        fi
    fi

    log "电源状态：$ac_power"

    if [[ "$ac_power" != "AC attached" ]]; then
        log "${RED}>>> 警告：未连接电源适配器！这会导致电池输出压力巨大！${NC}"
    fi
}

get_initial_voltage() {
    init_vol=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"Voltage"' | grep -v 'Adapter' | grep -v 'Legacy' | head -1 | awk '{print $NF}' | tr -d ',')
    if [ -z "$init_vol" ] || [ "$init_vol" -lt 8000 ] 2>/dev/null || [ "$init_vol" -gt 18000 ] 2>/dev/null; then
        init_vol=$(ioreg -l -n AppleSmartBattery 2>/dev/null | grep '"BatteryData"' | grep -oE '"Voltage"=[0-9]+' | head -1 | grep -oE '[0-9]+')
    fi
    if [ -n "$init_vol" ] && [ "$init_vol" -gt 8000 ] 2>/dev/null && [ "$init_vol" -lt 18000 ] 2>/dev/null; then
        log "初始电压：${init_vol}mV"
    else
        init_vol=""
    fi
}