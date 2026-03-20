#!/bin/bash

# ==============================================================================
# 图表报告模块 - 生成可视化图表报告
# ==============================================================================

# Check if Python and matplotlib are available
check_charting_deps() {
    if ! command -v python3 >/dev/null 2>&1; then
        log "${YELLOW}[图表] Python3 not found, skipping chart generation${NC}"
        return 1
    fi

    if ! python3 -c "import matplotlib" >/dev/null 2>&1; then
        log "${YELLOW}[图表] matplotlib not found, skipping chart generation${NC}"
        return 1
    fi

    return 0
}

# Generate enhanced thermal and frequency chart with throttling detection
generate_thermal_chart() {
    if [ ! -f "$THERMAL_LOG" ] || [ $(wc -l < "$THERMAL_LOG") -le 1 ]; then
        log "${YELLOW}[图表] 热数据不足，跳过温度图表生成${NC}"
        return 1
    fi

    local chart_file="${REPORT_DIR}/thermal_chart.png"

    python3 << EOF
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime
import sys
import os
import numpy as np

# Set Chinese font support
plt.rcParams['font.sans-serif'] = ['Arial Unicode MS', 'DejaVu Sans', 'SimHei', 'PingFang SC']
plt.rcParams['axes.unicode_minus'] = False

# Enhanced matplotlib settings for better visuals
plt.rcParams['figure.facecolor'] = 'white'
plt.rcParams['axes.facecolor'] = '#f8f9fa'
plt.rcParams['grid.alpha'] = 0.3
plt.rcParams['grid.linestyle'] = '--'

def add_throttling_annotations(ax, df, freq_col, time_col):
    """Add throttling detection and annotations"""
    # Define throttling thresholds
    low_freq_threshold = 1200  # MHz
    critical_freq_threshold = 1000  # MHz

    # Find throttling events
    low_freq_mask = df[freq_col] < low_freq_threshold
    critical_freq_mask = df[freq_col] < critical_freq_threshold

    # Color background based on throttling severity
    if low_freq_mask.any():
        # Find continuous throttling periods
        throttling_periods = []
        start_idx = None
        for i, is_throttled in enumerate(low_freq_mask):
            if is_throttled and start_idx is None:
                start_idx = i
            elif not is_throttled and start_idx is not None:
                throttling_periods.append((start_idx, i-1))
                start_idx = None
        if start_idx is not None:
            throttling_periods.append((start_idx, len(df)-1))

        # Add colored backgrounds for throttling periods
        for start, end in throttling_periods:
            if critical_freq_mask.iloc[start:end+1].any():
                # Critical throttling - red background
                ax.axvspan(df[time_col].iloc[start], df[time_col].iloc[end],
                          alpha=0.2, color='red', label='严重降频' if start == throttling_periods[0][0] else "")
            else:
                # Moderate throttling - yellow background
                ax.axvspan(df[time_col].iloc[start], df[time_col].iloc[end],
                          alpha=0.2, color='yellow', label='性能限制' if start == throttling_periods[0][0] else "")

try:
    # Read thermal data
    df = pd.read_csv('$THERMAL_LOG')

    # Convert timestamp to datetime
    df['Timestamp'] = pd.to_datetime(df['Timestamp'], format='%H:%M:%S')

    # Add calculated metrics
    if 'CPU_Freq_MHz' in df.columns:
        # Calculate frequency drop percentage
        if len(df) > 1:
            max_freq = df['CPU_Freq_MHz'].max()
            df['Freq_Drop_Pct'] = ((max_freq - df['CPU_Freq_MHz']) / max_freq * 100).round(1)

    # Create figure with enhanced layout
    fig = plt.figure(figsize=(16, 12))

    # Create a complex grid layout
    gs = fig.add_gridspec(3, 3, hspace=0.3, wspace=0.3)

    # Main temperature chart (top left, spans 2 columns)
    ax1 = fig.add_subplot(gs[0, :2])
    if 'CPU_Temp_C' in df.columns and df['CPU_Temp_C'].max() > 0:
        line1 = ax1.plot(df['Timestamp'], df['CPU_Temp_C'], 'r-', linewidth=3, label='CPU温度', alpha=0.8)
        ax1.set_ylabel('温度 (°C)', fontsize=12)
        ax1.set_title('CPU 温度监控', fontsize=14, fontweight='bold')

        # Add temperature thresholds
        ax1.axhline(y=85, color='orange', linestyle='--', alpha=0.7, label='警告温度 (85°C)')
        ax1.axhline(y=95, color='red', linestyle='--', alpha=0.7, label='临界温度 (95°C)')
    else:
        ax1.text(0.5, 0.5, '温度数据不可用', ha='center', va='center', transform=ax1.transAxes, fontsize=14)
    ax1.grid(True, alpha=0.3)
    ax1.legend(loc='upper left')
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # Frequency chart with throttling detection (top right, spans 2 columns)
    ax2 = fig.add_subplot(gs[1, :2])
    if 'CPU_Freq_MHz' in df.columns:
        line2 = ax2.plot(df['Timestamp'], df['CPU_Freq_MHz'], 'g-', linewidth=3, label='CPU频率', marker='o', markersize=3)
        ax2.set_ylabel('频率 (MHz)', fontsize=12)
        ax2.set_title('CPU 频率与降频检测', fontsize=14, fontweight='bold')

        # Add throttling detection
        add_throttling_annotations(ax2, df, 'CPU_Freq_MHz', 'Timestamp')

        # Add frequency baseline
        if df['CPU_Freq_MHz'].max() > 0:
            base_freq = df['CPU_Freq_MHz'].quantile(0.8)  # Use 80th percentile as baseline
            ax2.axhline(y=base_freq, color='blue', linestyle=':', alpha=0.7, label=f'基准频率 ({base_freq:.0f}MHz)')
    else:
        ax2.text(0.5, 0.5, '频率数据不可用', ha='center', va='center', transform=ax2.transAxes, fontsize=14)
    ax2.grid(True, alpha=0.3)
    ax2.legend(loc='upper right')
    ax2.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # Performance metrics panel (right column)
    ax3 = fig.add_subplot(gs[0, 2])

    # Create performance summary
    if 'CPU_Freq_MHz' in df.columns and df['CPU_Freq_MHz'].max() > 0:
        current_freq = df['CPU_Freq_MHz'].iloc[-1]
        max_freq = df['CPU_Freq_MHz'].max()
        min_freq = df['CPU_Freq_MHz'].min()
        avg_freq = df['CPU_Freq_MHz'].mean()

        # Performance score (0-100)
        if max_freq > 0:
            perf_score = (avg_freq / max_freq) * 100
        else:
            perf_score = 0

        # Display metrics
        metrics_text = f"""性能指标摘要

当前频率: {current_freq:.0f} MHz
最高频率: {max_freq:.0f} MHz
最低频率: {min_freq:.0f} MHz
平均频率: {avg_freq:.0f} MHz

性能评分: {perf_score:.1f}/100
"""

        # Color based on performance
        if perf_score >= 80:
            color = 'green'
        elif perf_score >= 60:
            color = 'orange'
        else:
            color = 'red'

        ax3.text(0.1, 0.9, metrics_text, transform=ax3.transAxes, fontsize=11,
                verticalalignment='top', bbox=dict(boxstyle='round', facecolor=color, alpha=0.1))
    else:
        ax3.text(0.5, 0.5, '性能数据\n不可用', ha='center', va='center',
                transform=ax3.transAxes, fontsize=12)
    ax3.set_xlim(0, 1)
    ax3.set_ylim(0, 1)
    ax3.axis('off')
    ax3.set_title('性能摘要', fontsize=14, fontweight='bold')

    # Throttling timeline (bottom, spans all columns)
    ax4 = fig.add_subplot(gs[2, :])
    if 'CPU_Freq_MHz' in df.columns and 'Clim_Pct' in df.columns:
        # Dual axis for frequency and throttling
        ax4_freq = ax4
        ax4_clim = ax4.twinx()

        # Plot frequency
        line1 = ax4_freq.plot(df['Timestamp'], df['CPU_Freq_MHz'], 'g-', linewidth=2, label='CPU频率', alpha=0.8)
        ax4_freq.set_ylabel('频率 (MHz)', fontsize=12, color='green')
        ax4_freq.tick_params(axis='y', labelcolor='green')

        # Plot throttling percentage
        line2 = ax4_clim.plot(df['Timestamp'], df['Clim_Pct'], 'r-', linewidth=2, label='系统限速', alpha=0.8)
        ax4_clim.set_ylabel('限速百分比 (%)', fontsize=12, color='red')
        ax4_clim.tick_params(axis='y', labelcolor='red')
        ax4_clim.set_ylim(0, 100)

        # Add throttling threshold line
        ax4_clim.axhline(y=85, color='orange', linestyle='--', alpha=0.7, label='正常阈值 (85%)')

        # Combine legends
        lines1, labels1 = ax4_freq.get_legend_handles_labels()
        lines2, labels2 = ax4_clim.get_legend_handles_labels()
        ax4_freq.legend(lines1 + lines2, labels1 + labels2, loc='upper left')

        ax4.set_title('频率与系统限速时间线', fontsize=14, fontweight='bold')
    else:
        ax4.text(0.5, 0.5, '频率/限速数据\n不可用', ha='center', va='center',
                transform=ax4.transAxes, fontsize=12)
    ax4.grid(True, alpha=0.3)
    ax4.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
    ax4.tick_params(axis='x', rotation=45)

    # Overall title
    fig.suptitle('MacBook 性能与降频综合监控报告', fontsize=18, fontweight='bold', y=0.98)

    # Add timestamp
    fig.text(0.99, 0.01, f'生成时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}',
             ha='right', va='bottom', fontsize=8, alpha=0.7)

    plt.tight_layout()
    plt.subplots_adjust(top=0.93)
    plt.savefig('$chart_file', dpi=200, bbox_inches='tight', facecolor='white')
    print(f"Enhanced thermal chart saved to: $chart_file")

except Exception as e:
    print(f"Error generating enhanced thermal chart: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    if [ $? -eq 0 ]; then
        log "${GREEN}[图表] 增强版温度与频率图表已生成: ${chart_file}${NC}"
        CHART_FILES+=("$chart_file")
        return 0
    else
        log "${RED}[图表] 增强版温度图表生成失败${NC}"
        return 1
    fi
}

# Generate enhanced power and voltage chart with power efficiency analysis
generate_power_chart() {
    local has_voltage_data=0
    local has_power_data=0
    local has_thermal_data=0

    if [ -f "$VOLTAGE_LOG" ] && [ $(wc -l < "$VOLTAGE_LOG") -gt 1 ]; then
        has_voltage_data=1
    fi

    if [ -f "$POWER_LOG" ] && [ $(wc -l < "$POWER_LOG") -gt 1 ]; then
        has_power_data=1
    fi

    if [ -f "$THERMAL_LOG" ] && [ $(wc -l < "$THERMAL_LOG") -gt 1 ]; then
        has_thermal_data=1
    fi

    if [ $has_voltage_data -eq 0 ] && [ $has_power_data -eq 0 ]; then
        log "${YELLOW}[图表] 电源数据不足，跳过电源图表生成${NC}"
        return 1
    fi

    local chart_file="${REPORT_DIR}/power_chart.png"

    python3 << EOF
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime
import sys
import os
import numpy as np

# Enhanced matplotlib settings
plt.rcParams['font.sans-serif'] = ['Arial Unicode MS', 'DejaVu Sans', 'SimHei', 'PingFang SC']
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams['figure.facecolor'] = 'white'
plt.rcParams['axes.facecolor'] = '#f8f9fa'
plt.rcParams['grid.alpha'] = 0.3
plt.rcParams['grid.linestyle'] = '--'

try:
    # Determine chart layout based on available data
    has_voltage = 0
    has_power = 0
    has_thermal = 0

    if os.path.exists('$VOLTAGE_LOG') and sum(1 for line in open('$VOLTAGE_LOG')) > 1:
        has_voltage = 1
    if os.path.exists('$POWER_LOG') and sum(1 for line in open('$POWER_LOG')) > 1:
        df_power = pd.read_csv('$POWER_LOG')
        if len(df_power) > 0:
            if pd.to_numeric(df_power['CPU_Package_W'], errors='coerce').notna().any() or \
               pd.to_numeric(df_power['GPU_Package_W'], errors='coerce').notna().any():
                has_power = 1
    if os.path.exists('$THERMAL_LOG') and sum(1 for line in open('$THERMAL_LOG')) > 1:
        df_thermal = pd.read_csv('$THERMAL_LOG')
        if len(df_thermal) > 0:
            has_thermal = 1

    # Create comprehensive power analysis figure
    fig = plt.figure(figsize=(16, 12))

    # Dynamic layout based on available data
    if has_power and has_voltage and has_thermal:
        gs = fig.add_gridspec(3, 2, hspace=0.25, wspace=0.3)
    elif has_power and (has_voltage or has_thermal):
        gs = fig.add_gridspec(2, 2, hspace=0.25, wspace=0.3)
    else:
        gs = fig.add_gridspec(1, 2, hspace=0.3, wspace=0.3)

    plot_idx = 0

    # 1. Power Consumption Analysis (main chart)
    if has_power:
        df_power['Timestamp'] = pd.to_datetime(df_power['Timestamp'], format='%H:%M:%S')

        if has_voltage and has_thermal:
            ax_power = fig.add_subplot(gs[0, :])
        else:
            ax_power = fig.add_subplot(gs[plot_idx, :])
            plot_idx += 1

        # Calculate total system power
        total_power = pd.Series(0, index=df_power.index)
        power_components = []

        # Plot CPU power
        if pd.to_numeric(df_power['CPU_Package_W'], errors='coerce').notna().any():
            cpu_power = pd.to_numeric(df_power['CPU_Package_W'], errors='coerce').fillna(0)
            ax_power.plot(df_power['Timestamp'], cpu_power, 'r-', linewidth=2.5,
                         marker='o', markersize=3, alpha=0.9, label='CPU 功耗')
            total_power += cpu_power
            power_components.append(('CPU', cpu_power.mean()))

        # Plot GPU power
        if pd.to_numeric(df_power['GPU_Package_W'], errors='coerce').notna().any():
            gpu_power = pd.to_numeric(df_power['GPU_Package_W'], errors='coerce').fillna(0)
            ax_power.plot(df_power['Timestamp'], gpu_power, 'b-', linewidth=2.5,
                         marker='s', markersize=3, alpha=0.9, label='GPU 功耗')
            total_power += gpu_power
            power_components.append(('GPU', gpu_power.mean()))

        # Plot Memory power
        if pd.to_numeric(df_power['Memory_W'], errors='coerce').notna().any():
            mem_power = pd.to_numeric(df_power['Memory_W'], errors='coerce').fillna(0)
            ax_power.plot(df_power['Timestamp'], mem_power, 'purple', linewidth=2.5,
                         marker='^', markersize=3, alpha=0.9, label='内存功耗')
            power_components.append(('Memory', mem_power.mean()))

        # Plot total power
        if len(power_components) > 1:
            ax_power.plot(df_power['Timestamp'], total_power, 'k-', linewidth=3,
                         alpha=0.8, label=f'总功耗 (峰值: {total_power.max():.1f}W)')

        # Add power efficiency zones
        ax_power.axhspan(0, 15, alpha=0.1, color='green', label='低功耗区域')
        ax_power.axhspan(15, 35, alpha=0.1, color='yellow', label='正常区域')
        ax_power.axhspan(35, total_power.max(), alpha=0.1, color='red', label='高功耗区域')

        ax_power.set_ylabel('功耗 (W)', fontsize=12)
        ax_power.set_title('⚡ 系统功耗详细分析', fontsize=14, fontweight='bold')
        ax_power.grid(True, alpha=0.3)
        ax_power.legend(loc='upper left', bbox_to_anchor=(1.02, 1))
        ax_power.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # 2. Power Efficiency Analysis (correlation with frequency)
    if has_power and has_thermal:
        ax_eff = fig.add_subplot(gs[1, 0])

        # Merge power and thermal data
        if has_thermal:
            df_thermal['Timestamp'] = pd.to_datetime(df_thermal['Timestamp'], format='%H:%M:%S')
            # Find common timestamps
            common_times = pd.merge_asof(df_power.sort_values('Timestamp'),
                                       df_thermal.sort_values('Timestamp'),
                                       on='Timestamp', direction='nearest', tolerance=pd.Timedelta('5s'))

            if len(common_times) > 0 and 'CPU_Freq_MHz' in common_times.columns:
                # Calculate power efficiency (frequency per watt)
                cpu_power = pd.to_numeric(common_times['CPU_Package_W'], errors='coerce')
                freq = pd.to_numeric(common_times['CPU_Freq_MHz'], errors='coerce')

                valid_mask = cpu_power.notna() & freq.notna() & (cpu_power > 0)
                if valid_mask.sum() > 5:
                    efficiency = freq[valid_mask] / cpu_power[valid_mask]

                    # Scatter plot
                    scatter = ax_eff.scatter(cpu_power[valid_mask], freq[valid_mask],
                                           c=efficiency, cmap='RdYlGn', alpha=0.7, s=50)
                    ax_eff.set_xlabel('CPU功耗 (W)', fontsize=10)
                    ax_eff.set_ylabel('CPU频率 (MHz)', fontsize=10)
                    ax_eff.set_title('功耗-频率效率分析', fontsize=12, fontweight='bold')
                    ax_eff.grid(True, alpha=0.3)

                    # Add colorbar
                    cbar = plt.colorbar(scatter, ax=ax_eff)
                    cbar.set_label('效率 (MHz/W)', fontsize=8)

                    # Add trend line
                    z = np.polyfit(cpu_power[valid_mask], freq[valid_mask], 1)
                    p = np.poly1d(z)
                    ax_eff.plot(cpu_power[valid_mask], p(cpu_power[valid_mask]),
                               "r--", alpha=0.8, linewidth=2, label=f'趋势线')
                    ax_eff.legend(fontsize=8)

    # 3. Power Statistics Panel
    if has_power:
        ax_stats = fig.add_subplot(gs[1, 1])
        ax_stats.axis('off')

        # Calculate power statistics
        stats_text = "功耗统计摘要:\n\n"
        if power_components:
            for component, avg_power in power_components:
                stats_text += f"• {component}平均: {avg_power:.2f}W\n"

            total_avg = sum(avg for _, avg in power_components)
            stats_text += f"• 总平均功耗: {total_avg:.2f}W\n"
            stats_text += f"• 峰值功耗: {total_power.max():.2f}W\n"
            stats_text += f"• 最低功耗: {total_power.min():.2f}W\n"

            # Power efficiency rating
            if has_thermal and 'CPU_Freq_MHz' in df_thermal.columns:
                avg_freq = df_thermal['CPU_Freq_MHz'].mean()
                if total_avg > 0:
                    efficiency_rating = avg_freq / total_avg
                    if efficiency_rating > 100:
                        efficiency_text = "🟢 优秀"
                    elif efficiency_rating > 60:
                        efficiency_text = "🟡 良好"
                    else:
                        efficiency_text = "🔴 需优化"
                    stats_text += f"• 能效评级: {efficiency_text}\n"

        ax_stats.text(0.05, 0.95, stats_text, transform=ax_stats.transAxes,
                     fontsize=10, verticalalignment='top',
                     bbox=dict(boxstyle='round,pad=0.5', facecolor='lightcyan', alpha=0.8))
        ax_stats.set_title('功耗统计', fontsize=12, fontweight='bold')

    # 4. Voltage Analysis (if available)
    if has_voltage:
        ax_volt = fig.add_subplot(gs[2, 0])
        df_volt = pd.read_csv('$VOLTAGE_LOG')
        df_volt['Timestamp'] = pd.to_datetime(df_volt['Timestamp'], format='%H:%M:%S')
        df_volt['Voltage_V'] = df_volt['Voltage_mV'] / 1000

        # Plot voltage with stability analysis
        ax_volt.plot(df_volt['Timestamp'], df_volt['Voltage_V'], 'b-', linewidth=2.5,
                    marker='o', markersize=3, alpha=0.8, label='电池电压')

        # Add voltage thresholds
        ax_volt.axhline(y=12.6, color='green', linestyle='--', alpha=0.7, label='满电 (12.6V)')
        ax_volt.axhline(y=11.1, color='orange', linestyle='--', alpha=0.7, label='警告 (11.1V)')
        ax_volt.axhline(y=10.5, color='red', linestyle='--', alpha=0.7, label='临界 (10.5V)')

        # Calculate voltage drop
        max_v = df_volt['Voltage_V'].max()
        min_v = df_volt['Voltage_V'].min()
        voltage_drop = max_v - min_v

        ax_volt.set_ylabel('电压 (V)', fontsize=10)
        ax_volt.set_title(f'电池电压稳定性 (压降: {voltage_drop:.2f}V)', fontsize=12, fontweight='bold')
        ax_volt.grid(True, alpha=0.3)
        ax_volt.legend(fontsize=8)
        ax_volt.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # 5. Temperature-Power Correlation (if both available)
    if has_power and has_thermal and 'CPU_Temp_C' in df_thermal.columns:
        ax_corr = fig.add_subplot(gs[2, 1])

        # Merge data
        merged_data = pd.merge_asof(df_power.sort_values('Timestamp'),
                                   df_thermal.sort_values('Timestamp'),
                                   on='Timestamp', direction='nearest', tolerance=pd.Timedelta('5s'))

        if len(merged_data) > 0:
            temp = pd.to_numeric(merged_data['CPU_Temp_C'], errors='coerce')
            power = pd.to_numeric(merged_data['CPU_Package_W'], errors='coerce')

            valid_mask = temp.notna() & power.notna()
            if valid_mask.sum() > 5:
                # Scatter plot with correlation
                ax_corr.scatter(temp[valid_mask], power[valid_mask],
                               alpha=0.6, s=40, c='purple')

                # Add correlation coefficient
                correlation = temp[valid_mask].corr(power[valid_mask])
                ax_corr.text(0.05, 0.95, f'相关系数: {correlation:.3f}',
                           transform=ax_corr.transAxes, fontsize=10,
                           bbox=dict(boxstyle='round', facecolor='white', alpha=0.8))

                # Add trend line
                z = np.polyfit(temp[valid_mask], power[valid_mask], 1)
                p = np.poly1d(z)
                temp_range = np.linspace(temp[valid_mask].min(), temp[valid_mask].max(), 100)
                ax_corr.plot(temp_range, p(temp_range), "r-", alpha=0.8, linewidth=2)

                ax_corr.set_xlabel('CPU温度 (°C)', fontsize=10)
                ax_corr.set_ylabel('CPU功耗 (W)', fontsize=10)
                ax_corr.set_title('温度-功耗相关性分析', fontsize=12, fontweight='bold')
                ax_corr.grid(True, alpha=0.3)

    # Overall title and timestamp
    fig.suptitle('MacBook 电源管理与功耗分析', fontsize=18, fontweight='bold', y=0.98)
    fig.text(0.99, 0.01, f'生成时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}',
             ha='right', va='bottom', fontsize=9, alpha=0.7)

    plt.tight_layout()
    plt.subplots_adjust(top=0.93)
    plt.savefig('$chart_file', dpi=200, bbox_inches='tight', facecolor='white')
    print(f"Enhanced power chart saved to: $chart_file")

except Exception as e:
    print(f"Error generating enhanced power chart: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    if [ $? -eq 0 ]; then
        log "${GREEN}[图表] 增强版电源图表已生成: ${chart_file}${NC}"
        CHART_FILES+=("$chart_file")
        return 0
    else
        log "${RED}[图表] 增强版电源图表生成失败${NC}"
        return 1
    fi
}

# Generate disk I/O chart
generate_disk_chart() {
    if [ ! -f "$DISK_LOG" ] || [ $(wc -l < "$DISK_LOG") -le 1 ]; then
        log "${YELLOW}[图表] 磁盘I/O数据不足，跳过磁盘图表生成${NC}"
        return 1
    fi

    local chart_file="${REPORT_DIR}/disk_chart.png"

    python3 << EOF
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime
import sys
import os

# Set Chinese font support
plt.rcParams['font.sans-serif'] = ['Arial Unicode MS', 'DejaVu Sans', 'SimHei']
plt.rcParams['axes.unicode_minus'] = False

try:
    df = pd.read_csv('$DISK_LOG')
    df['Timestamp'] = pd.to_datetime(df['Timestamp'], format='%H:%M:%S')

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8))
    fig.suptitle('磁盘I/O性能监控报告', fontsize=16, fontweight='bold')

    # Throughput
    ax1.plot(df['Timestamp'], df['MB_s'], 'g-', linewidth=2, label='吞吐量')
    ax1.set_ylabel('吞吐量 (MB/s)')
    ax1.set_title('磁盘吞吐量')
    ax1.grid(True, alpha=0.3)
    ax1.legend()
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
    ax1.tick_params(axis='x', rotation=45)

    # IOPS
    ax2.plot(df['Timestamp'], df['TPS'], 'b-', linewidth=2, label='IOPS')
    ax2.set_ylabel('IOPS')
    ax2.set_xlabel('时间')
    ax2.set_title('磁盘IOPS')
    ax2.grid(True, alpha=0.3)
    ax2.legend()
    ax2.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
    ax2.tick_params(axis='x', rotation=45)

    plt.tight_layout()
    plt.savefig('$chart_file', dpi=150, bbox_inches='tight')
    print(f"Disk chart saved to: $chart_file")

except Exception as e:
    print(f"Error generating disk chart: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    if [ $? -eq 0 ]; then
        log "${GREEN}[图表] 磁盘I/O图表已生成: ${chart_file}${NC}"
        CHART_FILES+=("$chart_file")
        return 0
    else
        log "${RED}[图表] 磁盘I/O图表生成失败${NC}"
        return 1
    fi
}

# Generate dedicated throttling analysis chart
generate_throttling_chart() {
    if [ ! -f "$THERMAL_LOG" ] || [ $(wc -l < "$THERMAL_LOG") -le 1 ]; then
        log "${YELLOW}[图表] 降频数据不足，跳过降频分析图表${NC}"
        return 1
    fi

    local chart_file="${REPORT_DIR}/throttling_analysis.png"

    python3 << EOF
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime
import sys
import os
import numpy as np
from matplotlib.patches import Rectangle

# Set Chinese font support
plt.rcParams['font.sans-serif'] = ['Arial Unicode MS', 'DejaVu Sans', 'SimHei', 'PingFang SC']
plt.rcParams['axes.unicode_minus'] = False

# Enhanced matplotlib settings
plt.rcParams['figure.facecolor'] = 'white'
plt.rcParams['axes.facecolor'] = '#f8f9fa'
plt.rcParams['grid.alpha'] = 0.3
plt.rcParams['grid.linestyle'] = '--'

try:
    # Read thermal data
    df = pd.read_csv('$THERMAL_LOG')
    df['Timestamp'] = pd.to_datetime(df['Timestamp'], format='%H:%M:%S')

    # Create comprehensive throttling analysis
    fig = plt.figure(figsize=(18, 14))
    gs = fig.add_gridspec(4, 3, hspace=0.25, wspace=0.3)

    # 1. CPU Frequency Timeline with Thresholds (top)
    ax1 = fig.add_subplot(gs[0, :])
    if 'CPU_Freq_MHz' in df.columns:
        ax1.plot(df['Timestamp'], df['CPU_Freq_MHz'], 'g-', linewidth=3,
                marker='o', markersize=4, alpha=0.8, label='CPU频率')

        # Add frequency thresholds
        ax1.axhline(y=800, color='red', linestyle='--', linewidth=2, alpha=0.8,
                   label='严重降频线 (800MHz)')
        ax1.axhline(y=1200, color='orange', linestyle='--', linewidth=2, alpha=0.8,
                   label='性能警告线 (1200MHz)')
        ax1.axhline(y=2000, color='blue', linestyle=':', linewidth=2, alpha=0.8,
                   label='基准频率 (2000MHz)')

        # Color background based on performance zones
        ax1.axhspan(0, 800, alpha=0.2, color='red', label='危险区域')
        ax1.axhspan(800, 1200, alpha=0.1, color='orange', label='警告区域')
        ax1.axhspan(1200, 2000, alpha=0.1, color='yellow', label='限制区域')
        ax1.axhspan(2000, df['CPU_Freq_MHz'].max(), alpha=0.1, color='green', label='正常区域')

        ax1.set_ylabel('频率 (MHz)', fontsize=12)
        ax1.set_title('📊 CPU 频率变化与降频检测时间线', fontsize=14, fontweight='bold')
        ax1.grid(True, alpha=0.3)
        ax1.legend(bbox_to_anchor=(1.05, 1), loc='upper left')
        ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # 2. System Throttling Analysis (second row, left)
    ax2 = fig.add_subplot(gs[1, 0])
    if 'Clim_Pct' in df.columns:
        # Calculate throttling statistics
        throttled_time = (df['Clim_Pct'] < 85).sum()
        total_time = len(df)
        throttling_pct = (throttled_time / total_time) * 100

        # Create pie chart of throttling distribution
        labels = ['正常性能\n(≥85%)', '性能受限\n(70-84%)', '严重降频\n(<70%)']
        sizes = [
            (df['Clim_Pct'] >= 85).sum(),
            ((df['Clim_Pct'] >= 70) & (df['Clim_Pct'] < 85)).sum(),
            (df['Clim_Pct'] < 70).sum()
        ]
        colors = ['green', 'orange', 'red']
        explode = (0, 0.1, 0.2) if sizes[2] > 0 else (0, 0.1, 0)

        wedges, texts, autotexts = ax2.pie(sizes, labels=labels, colors=colors, autopct='%1.1f%%',
                                          explode=explode, shadow=True, startangle=90)
        ax2.set_title(f'性能状态分布\n(总限制时间: {throttling_pct:.1f}%)', fontsize=12, fontweight='bold')

    # 3. Frequency Distribution Histogram (second row, middle)
    ax3 = fig.add_subplot(gs[1, 1])
    if 'CPU_Freq_MHz' in df.columns:
        # Create frequency distribution
        freq_data = df['CPU_Freq_MHz'].dropna()
        if len(freq_data) > 0:
            n, bins, patches = ax3.hist(freq_data, bins=20, alpha=0.7, color='skyblue', edgecolor='black')

            # Color bars based on frequency ranges
            for i, (patch, bin_edge) in enumerate(zip(patches, bins[:-1])):
                if bin_edge < 800:
                    patch.set_facecolor('red')
                elif bin_edge < 1200:
                    patch.set_facecolor('orange')
                elif bin_edge < 2000:
                    patch.set_facecolor('yellow')
                else:
                    patch.set_facecolor('green')

            ax3.axvline(freq_data.mean(), color='blue', linestyle='--', linewidth=2,
                       label=f'平均: {freq_data.mean():.0f}MHz')
            ax3.axvline(freq_data.quantile(0.1), color='red', linestyle=':', linewidth=2,
                       label=f'10%分位: {freq_data.quantile(0.1):.0f}MHz')

            ax3.set_xlabel('频率 (MHz)', fontsize=10)
            ax3.set_ylabel('采样点数', fontsize=10)
            ax3.set_title('频率分布直方图', fontsize=12, fontweight='bold')
            ax3.legend(fontsize=8)
            ax3.grid(True, alpha=0.3)

    # 4. Throttling Timeline (second row, right)
    ax4 = fig.add_subplot(gs[1, 2])
    if 'Clim_Pct' in df.columns:
        ax4.plot(df['Timestamp'], df['Clim_Pct'], 'r-', linewidth=2, alpha=0.8)
        ax4.axhline(y=85, color='green', linestyle='--', alpha=0.7, label='正常线 (85%)')
        ax4.axhline(y=70, color='orange', linestyle='--', alpha=0.7, label='警告线 (70%)')
        ax4.fill_between(df['Timestamp'], df['Clim_Pct'], 85,
                        where=(df['Clim_Pct'] < 85), alpha=0.3, color='red',
                        label='限制区域')
        ax4.set_ylabel('系统限速 (%)', fontsize=10)
        ax4.set_title('系统限速时间线', fontsize=12, fontweight='bold')
        ax4.set_ylim(0, 100)
        ax4.legend(fontsize=8)
        ax4.grid(True, alpha=0.3)
        ax4.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    # 5. Performance Impact Analysis (third row, spans 2 columns)
    ax5 = fig.add_subplot(gs[2, :2])
    if 'CPU_Freq_MHz' in df.columns and 'Clim_Pct' in df.columns:
        # Create performance impact timeline
        # Calculate performance loss percentage
        max_freq = df['CPU_Freq_MHz'].max()
        if max_freq > 0:
            performance_loss = ((max_freq - df['CPU_Freq_MHz']) / max_freq * 100)

            # Plot performance metrics
            ax5_twin = ax5.twinx()

            # Performance loss
            line1 = ax5.fill_between(df['Timestamp'], 0, performance_loss,
                                    alpha=0.3, color='red', label='性能损失')
            ax5.plot(df['Timestamp'], performance_loss, 'r-', linewidth=2,
                    label='性能损失百分比')
            ax5.set_ylabel('性能损失 (%)', fontsize=12, color='red')
            ax5.tick_params(axis='y', labelcolor='red')

            # System throttling overlay
            line2 = ax5_twin.plot(df['Timestamp'], df['Clim_Pct'], 'b-', linewidth=2,
                                 alpha=0.7, label='系统限速')
            ax5_twin.set_ylabel('系统限速 (%)', fontsize=12, color='blue')
            ax5_twin.tick_params(axis='y', labelcolor='blue')
            ax5_twin.set_ylim(0, 100)

            # Add impact severity zones
            ax5.axhspan(0, 20, alpha=0.1, color='green', label='轻微影响')
            ax5.axhspan(20, 50, alpha=0.1, color='orange', label='中等影响')
            ax5.axhspan(50, 100, alpha=0.1, color='red', label='严重影响')

            ax5.set_title('📈 性能损失影响分析', fontsize=14, fontweight='bold')
            ax5.grid(True, alpha=0.3)
            ax5.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

            # Combine legends
            lines1, labels1 = ax5.get_legend_handles_labels()
            lines2, labels2 = ax5_twin.get_legend_handles_labels()
            ax5.legend(lines1 + lines2, labels1 + labels2, loc='upper left')

    # 6. Recommendations Panel (third row, right)
    ax6 = fig.add_subplot(gs[2, 2])
    ax6.axis('off')

    # Generate recommendations based on data
    recommendations = []
    if 'CPU_Freq_MHz' in df.columns:
        min_freq = df['CPU_Freq_MHz'].min()
        avg_freq = df['CPU_Freq_MHz'].mean()

        if min_freq < 800:
            recommendations.append("🔴 立即检查散热系统")
            recommendations.append("🔴 清理风扇和散热片")
            recommendations.append("🔴 重置SMC控制器")
        elif avg_freq < 1500:
            recommendations.append("🟡 监控温度趋势")
            recommendations.append("🟡 检查高负载进程")
            recommendations.append("🟡 改善通风条件")
        else:
            recommendations.append("🟢 性能表现良好")
            recommendations.append("🟢 定期维护散热")
            recommendations.append("🟢 监控电池健康")

    rec_text = "智能建议:\n\n" + "\n".join(recommendations)

    ax6.text(0.05, 0.95, rec_text, transform=ax6.transAxes, fontsize=10,
            verticalalignment='top', bbox=dict(boxstyle='round,pad=0.5',
            facecolor='lightblue', alpha=0.8))
    ax6.set_title('💡 智能诊断建议', fontsize=12, fontweight='bold')

    # 7. Statistics Summary (bottom row)
    ax7 = fig.add_subplot(gs[3, :])
    ax7.axis('off')

    # Generate comprehensive statistics
    stats_text = ""
    if 'CPU_Freq_MHz' in df.columns and 'Clim_Pct' in df.columns:
        # Calculate detailed statistics
        freq_data = df['CPU_Freq_MHz'].dropna()
        clim_data = df['Clim_Pct'].dropna()

        if len(freq_data) > 0 and len(clim_data) > 0:
            stats_text = f"""
📊 降频统计分析摘要:

频率统计:
• 最高频率: {freq_data.max():.0f} MHz
• 最低频率: {freq_data.min():.0f} MHz
• 平均频率: {freq_data.mean():.0f} MHz
• 频率标准差: {freq_data.std():.0f} MHz

限速统计:
• 最高限速: {clim_data.max():.1f}%
• 最低限速: {clim_data.min():.1f}%
• 平均限速: {clim_data.mean():.1f}%
• 限速<85%时间: {((clim_data < 85).sum() / len(clim_data) * 100):.1f}%

性能评估:
• 严重降频事件: {(freq_data < 800).sum()} 次
• 性能限制事件: {((freq_data >= 800) & (freq_data < 1200)).sum()} 次
• 正常运行时间: {((clim_data >= 85).sum() / len(clim_data) * 100):.1f}%
"""

    ax7.text(0.02, 0.95, stats_text, transform=ax7.transAxes, fontsize=11,
            verticalalignment='top', fontfamily='monospace',
            bbox=dict(boxstyle='round,pad=0.5', facecolor='lightgray', alpha=0.5))

    # Overall title
    fig.suptitle('MacBook 降频深度分析报告', fontsize=20, fontweight='bold', y=0.98)

    # Add timestamp
    fig.text(0.99, 0.01, f'生成时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")} | 数据点数: {len(df)}',
             ha='right', va='bottom', fontsize=9, alpha=0.7)

    plt.tight_layout()
    plt.subplots_adjust(top=0.94)
    plt.savefig('$chart_file', dpi=250, bbox_inches='tight', facecolor='white')
    print(f"Throttling analysis chart saved to: $chart_file")

except Exception as e:
    print(f"Error generating throttling analysis chart: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    if [ $? -eq 0 ]; then
        log "${GREEN}[图表] 降频深度分析图表已生成: ${chart_file}${NC}"
        CHART_FILES+=("$chart_file")
        return 0
    else
        log "${RED}[图表] 降频分析图表生成失败${NC}"
        return 1
    fi
}

# Generate comprehensive summary chart
generate_summary_chart() {
    local has_thermal=0
    local has_voltage=0
    local has_disk=0

    if [ -f "$THERMAL_LOG" ] && [ $(wc -l < "$THERMAL_LOG") -gt 1 ]; then
        has_thermal=1
    fi
    if [ -f "$VOLTAGE_LOG" ] && [ $(wc -l < "$VOLTAGE_LOG") -gt 1 ]; then
        has_voltage=1
    fi
    if [ -f "$DISK_LOG" ] && [ $(wc -l < "$DISK_LOG") -gt 1 ]; then
        has_disk=1
    fi

    if [ $has_thermal -eq 0 ] && [ $has_voltage -eq 0 ] && [ $has_disk -eq 0 ]; then
        log "${YELLOW}[图表] 数据不足，跳过综合图表生成${NC}"
        return 1
    fi

    local chart_file="${REPORT_DIR}/summary_chart.png"

    python3 << EOF
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import datetime
import sys
import os

# Set Chinese font support
plt.rcParams['font.sans-serif'] = ['Arial Unicode MS', 'DejaVu Sans', 'SimHei']
plt.rcParams['axes.unicode_minus'] = False

try:
    # Determine number of subplots needed
    subplot_count = 0
    if os.path.exists('$THERMAL_LOG') and sum(1 for line in open('$THERMAL_LOG')) > 1:
        subplot_count += 2  # CPU Temp + Frequency
    if os.path.exists('$VOLTAGE_LOG') and sum(1 for line in open('$VOLTAGE_LOG')) > 1:
        subplot_count += 1  # Voltage
    if os.path.exists('$DISK_LOG') and sum(1 for line in open('$DISK_LOG')) > 1:
        subplot_count += 1  # Disk throughput

    if subplot_count == 0:
        print("No data available for summary chart")
        sys.exit(0)

    # Create figure
    fig, axes = plt.subplots(subplot_count, 1, figsize=(12, 4*subplot_count))
    if subplot_count == 1:
        axes = [axes]

    fig.suptitle('系统性能综合监控报告', fontsize=16, fontweight='bold')

    plot_idx = 0

    # Thermal data
    if os.path.exists('$THERMAL_LOG') and sum(1 for line in open('$THERMAL_LOG')) > 1:
        df_therm = pd.read_csv('$THERMAL_LOG')
        df_therm['Timestamp'] = pd.to_datetime(df_therm['Timestamp'], format='%H:%M:%S')

        # CPU Temperature
        axes[plot_idx].plot(df_therm['Timestamp'], df_therm['CPU_Temp_C'], 'r-', linewidth=2, label='CPU温度')
        axes[plot_idx].set_ylabel('温度 (°C)')
        axes[plot_idx].set_title('CPU 温度')
        axes[plot_idx].grid(True, alpha=0.3)
        axes[plot_idx].legend()
        axes[plot_idx].xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
        axes[plot_idx].tick_params(axis='x', rotation=45)
        plot_idx += 1

        # CPU Frequency
        axes[plot_idx].plot(df_therm['Timestamp'], df_therm['CPU_Freq_MHz'], 'g-', linewidth=2, label='CPU频率')
        axes[plot_idx].set_ylabel('频率 (MHz)')
        axes[plot_idx].set_title('CPU 频率')
        axes[plot_idx].grid(True, alpha=0.3)
        axes[plot_idx].legend()
        axes[plot_idx].xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
        axes[plot_idx].tick_params(axis='x', rotation=45)
        plot_idx += 1

    # Power data (new format with CPU, GPU, Memory power)
    if os.path.exists('$POWER_LOG') and sum(1 for line in open('$POWER_LOG')) > 1:
        df_power = pd.read_csv('$POWER_LOG')
        if len(df_power) > 0:
            # Check if we have any numeric power data
            if pd.to_numeric(df_power['CPU_Package_W'], errors='coerce').notna().any() or \
               pd.to_numeric(df_power['GPU_Package_W'], errors='coerce').notna().any():
                df_power['Timestamp'] = pd.to_datetime(df_power['Timestamp'], format='%H:%M:%S')

                # Plot CPU power if available
                if pd.to_numeric(df_power['CPU_Package_W'], errors='coerce').notna().any():
                    axes[plot_idx].plot(df_power['Timestamp'], df_power['CPU_Package_W'], 'r-', linewidth=2, label='CPU功耗')

                # Plot GPU power if available
                if pd.to_numeric(df_power['GPU_Package_W'], errors='coerce').notna().any():
                    axes[plot_idx].plot(df_power['Timestamp'], df_power['GPU_Package_W'], 'g-', linewidth=2, label='GPU功耗')

                axes[plot_idx].set_ylabel('功耗 (W)')
                axes[plot_idx].set_title('系统功耗')
                axes[plot_idx].grid(True, alpha=0.3)
                axes[plot_idx].legend()
                axes[plot_idx].xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
                axes[plot_idx].tick_params(axis='x', rotation=45)
                plot_idx += 1

    # Voltage data (fallback for older data format)
    elif os.path.exists('$VOLTAGE_LOG') and sum(1 for line in open('$VOLTAGE_LOG')) > 1:
        df_volt = pd.read_csv('$VOLTAGE_LOG')
        df_volt['Timestamp'] = pd.to_datetime(df_volt['Timestamp'], format='%H:%M:%S')

        axes[plot_idx].plot(df_volt['Timestamp'], df_volt['Voltage_mV']/1000, 'b-', linewidth=2, label='电压')
        axes[plot_idx].set_ylabel('电压 (V)')
        axes[plot_idx].set_title('电池电压')
        axes[plot_idx].grid(True, alpha=0.3)
        axes[plot_idx].legend()
        axes[plot_idx].xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
        axes[plot_idx].tick_params(axis='x', rotation=45)
        plot_idx += 1

    # Disk data
    if os.path.exists('$DISK_LOG') and sum(1 for line in open('$DISK_LOG')) > 1:
        df_disk = pd.read_csv('$DISK_LOG')
        df_disk['Timestamp'] = pd.to_datetime(df_disk['Timestamp'], format='%H:%M:%S')

        axes[plot_idx].plot(df_disk['Timestamp'], df_disk['MB_s'], 'm-', linewidth=2, label='吞吐量')
        axes[plot_idx].set_ylabel('吞吐量 (MB/s)')
        axes[plot_idx].set_title('磁盘吞吐量')
        axes[plot_idx].grid(True, alpha=0.3)
        axes[plot_idx].legend()
        axes[plot_idx].xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
        axes[plot_idx].tick_params(axis='x', rotation=45)

    plt.tight_layout()
    plt.savefig('$chart_file', dpi=150, bbox_inches='tight')
    print(f"Summary chart saved to: $chart_file")

except Exception as e:
    print(f"Error generating summary chart: {e}", file=sys.stderr)
    sys.exit(1)
EOF

    if [ $? -eq 0 ]; then
        log "${GREEN}[图表] 综合图表已生成: ${chart_file}${NC}"
        CHART_FILES+=("$chart_file")
        return 0
    else
        log "${RED}[图表] 综合图表生成失败${NC}"
        return 1
    fi
}

# Main function to generate all charts
generate_all_charts() {
    log "${CYAN}=== 生成图表报告 ===${NC}"

    # Initialize chart files array
    CHART_FILES=()

    # Create report directory if it doesn't exist
    mkdir -p "$REPORT_DIR"

    # Check dependencies
    if ! check_charting_deps; then
        log "${YELLOW}[图表] 缺少依赖，跳过所有图表生成${NC}"
        return 1
    fi

    # Generate individual charts
    generate_thermal_chart
    generate_power_chart
    generate_disk_chart
    generate_summary_chart
    generate_throttling_chart

    # Report results
    if [ ${#CHART_FILES[@]} -gt 0 ]; then
        log "${GREEN}[图表] 成功生成 ${#CHART_FILES[@]} 个图表文件:${NC}"
        for chart in "${CHART_FILES[@]}"; do
            log "  - $(basename "$chart")"
        done
        return 0
    else
        log "${YELLOW}[图表] 未生成任何图表文件${NC}"
        return 1
    fi
}