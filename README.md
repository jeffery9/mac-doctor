# mac-doctor

**macOS Intel CPU + GPU Stress Testing and Performance Diagnostic Tool**

`mac-doctor` is a comprehensive diagnostic tool designed specifically for Intel-based Macs. It helps identify hardware bottlenecks, thermal throttling issues, and power delivery problems by systematically stressing the CPU, GPU, and memory while monitoring low-level system sensors.

## Features

*   **Multi-Phase Stress Testing:** Offers a complete diagnostic run covering CPU-only, GPU-only, and combined stress tests with cooling periods in between.
*   **Targeted Testing Modes:** Choose to stress only specific components (CPU, GPU, or Dual Load) for focused troubleshooting.
*   **Deep Hardware Monitoring:** Tracks real-time telemetry including:
    *   CPU & GPU Temperatures
    *   Fan RPM
    *   CPU Frequency & Throttling Limits (OS & Hardware levels)
    *   `kernel_task` usage (OS preemptive cooling)
    *   Hardware Plimit (Power constraints)
    *   PROCHOT triggers (Thermal critical limits)
    *   Battery Voltage and Current drops
*   **Kernel Log Analysis:** Monitors system logs for critical hardware events like voltage droop, thermal limits, and overcurrent protection.
*   **Native Metal GPU Stressing:** Uses a compiled Swift/Metal application (`gpu_stress_test.swift`) to efficiently and fully load the GPU.
*   **Detailed Diagnostics Report:** Generates a comprehensive summary identifying the root causes of performance degradation (e.g., dried thermal paste, degraded battery unable to deliver peak current).

## Prerequisites

*   **OS:** macOS (designed for Intel-based Macs)
*   **Permissions:** `sudo` privileges are highly recommended and often required to read accurate hardware sensor data (temperatures, fan speeds, real CPU frequencies) and kernel logs.
*   **Dependencies:** Uses built-in macOS tools (`openssl`, `dd`, `pmset`, `ioreg`, `powermetrics`, `top`, `sysctl`, `swiftc`).

## Usage

1.  Clone or download the repository to your Mac.
2.  Open a terminal and navigate to the `mac-doctor` directory.
3.  Run the main script with `sudo` for full diagnostic capabilities:

```bash
sudo ./stress_no_gltest.sh
```

4.  Follow the interactive prompts to select your desired testing mode:
    *   `1)` Full phased test (CPU -> Cooldown -> GPU -> Cooldown -> Dual Stress) [Comprehensive, ~21 mins]
    *   `2)` CPU test only (~5 mins)
    *   `3)` GPU test only (~5 mins)
    *   `4)` Dual stress test (CPU+GPU) (~5 mins)

**Warning:**
*   Please save all your work before running this tool. The system may become unresponsive, crash, or reboot during extreme stress testing.
*   The device will get very hot, and fans will run at maximum speed.
*   Devices with severely degraded batteries may experience sudden shutdowns when placed under maximum load.

## Output

The tool creates a temporary directory (e.g., `/tmp/stress_diag_YYYYMMDD_HHMMSS`) to store detailed logs in CSV and text formats for further analysis. These logs include:
*   `stress_summary.log`: The main output and diagnostic summary.
*   `voltage_curve.csv`: Battery voltage and current data.
*   `thermal_log.csv`: Temperature, frequency, and throttling data.
*   `power_log.csv`: Power consumption data.
*   `kernel_errors.log`: Filtered hardware-related kernel messages.

This directory is automatically cleaned up upon a system reboot.
