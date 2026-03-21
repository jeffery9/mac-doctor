#!/usr/bin/env python3
"""
Core Python monitoring backend for macOS hardware sensors.
Provides accurate readings for temperature, power, and performance metrics.
"""

import sys
import time
import csv
import signal
import argparse
import subprocess
import json
from datetime import datetime
from typing import Dict, Optional, List

# Constants for Intel CPU power estimation
CPU_POWER_CONSTANTS = {
    'idle_watts': 5.0,      # Base idle power
    'max_watts': 70.0,      # Maximum power under full load
    'frequency_factor': 0.7, # Power scaling with frequency
    'load_factor': 0.8      # Power scaling with load
}

class MacOSMonitor:
    """Main monitoring class for macOS hardware sensors."""

    def __init__(self):
        self.running = True
        self.start_time = time.time()
        self.cpu_frequency_cache = {}
        self.last_cpu_times = {}
        self.powermetrics_process = None
        self.powermetrics_output = ""

    def signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully."""
        self.running = False

    def start_continuous_powermetrics(self):
        """Start continuous powermetrics process for efficient data collection."""
        if self.powermetrics_process is None:
            try:
                self.powermetrics_process = subprocess.Popen(
                    ['powermetrics', '--samplers', 'smc,cpu_power,gpu_power', '-i', '300'],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1
                )
                print("Continuous powermetrics monitoring started", file=sys.stderr)
            except (subprocess.SubprocessError, PermissionError) as e:
                print(f"Failed to start continuous powermetrics: {e}", file=sys.stderr)
                self.powermetrics_process = None

    def stop_continuous_powermetrics(self):
        """Stop continuous powermetrics process."""
        if self.powermetrics_process is not None:
            self.powermetrics_process.terminate()
            try:
                self.powermetrics_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.powermetrics_process.kill()
            self.powermetrics_process = None
            print("Continuous powermetrics monitoring stopped", file=sys.stderr)

    def read_powermetrics_data(self, timeout=2) -> str:
        """Read next available powermetrics data."""
        if self.powermetrics_process is None:
            return ""

        try:
            # Read one line at a time
            line = self.powermetrics_process.stdout.readline()
            if line:
                return line
            return ""
        except Exception as e:
            print(f"Error reading powermetrics data: {e}", file=sys.stderr)
            return ""

    def parse_powermetrics_sensors(self, data: str) -> Dict[str, float]:
        """Parse sensor data from powermetrics output."""
        sensors = {}

        # Parse CPU temperature
        if 'CPU die temperature:' in data:
            try:
                parts = data.split('CPU die temperature:')
                if len(parts) > 1:
                    temp_str = parts[1].strip().split()[0]
                    sensors['cpu_temp'] = float(temp_str)
            except (ValueError, IndexError):
                pass

        # Parse GPU temperature
        if 'GPU die temperature:' in data:
            try:
                parts = data.split('GPU die temperature:')
                if len(parts) > 1:
                    temp_str = parts[1].strip().split()[0]
                    sensors['gpu_temp'] = float(temp_str)
            except (ValueError, IndexError):
                pass

        # Parse fan speed
        if 'Fan:' in data:
            try:
                parts = data.split('Fan:')
                if len(parts) > 1:
                    fan_str = parts[1].strip().split()[0]
                    sensors['fan_rpm'] = int(float(fan_str))
            except (ValueError, IndexError):
                pass

        return sensors

    def get_cpu_temperature(self) -> Optional[float]:
        """Get CPU temperature using powermetrics, osx-cpu-temp, or fallback to ioreg."""
        # Try powermetrics first (most reliable on macOS)
        try:
            result = subprocess.run(['powermetrics', '--samplers', 'smc', '-n', '1', '-i', '100'],
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                # Use string find instead of line iteration for better performance
                output = result.stdout
                start_idx = output.find('CPU die temperature:')
                if start_idx != -1:
                    # Extract temperature from the found position
                    temp_part = output[start_idx + len('CPU die temperature:'):].lstrip()
                    temp_str = temp_part.split()[0] if temp_part else ""
                    if temp_str:
                        return float(temp_str)
        except (subprocess.TimeoutExpired, ValueError, subprocess.SubprocessError, PermissionError):
            pass

        # Try osx-cpu-temp second
        try:
            result = subprocess.run(['osx-cpu-temp', '-C'],
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                temp_str = result.stdout.strip()
                # Remove any ANSI codes or extra text
                temp_str = temp_str.replace('°C', '').strip()
                return float(temp_str)
        except (subprocess.TimeoutExpired, ValueError, subprocess.SubprocessError, FileNotFoundError):
            pass

        # Fallback to ioreg
        return self.get_cpu_temperature_ioreg()

    def get_cpu_temperature_ioreg(self) -> Optional[float]:
        """Get CPU temperature using ioreg as fallback."""
        try:
            cmd = ['ioreg', '-r', '-c', 'IOHWSensor', '-d', '2']
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                # Use regex to find CPU temperature more efficiently
                import re
                # Pattern to match temperature sensor current-value
                temp_pattern = r'"type" = <temperature>.*?"current-value" = ([0-9]+)'
                matches = re.finditer(temp_pattern, result.stdout, re.DOTALL)
                if matches:
                    # Return the first temperature found (usually CPU)
                    for match in matches:
                        value = int(match.group(1))
                        temp_kelvin = value / 1000000.0
                        return temp_kelvin - 273.15
                return None
        except (subprocess.TimeoutExpired, ValueError, subprocess.SubprocessError, re.error):
            pass
        return None

    def get_gpu_temperature(self) -> Optional[float]:
        """Get GPU temperature using powermetrics or ioreg."""
        # Try powermetrics first
        try:
            result = subprocess.run(['powermetrics', '--samplers', 'smc', '-n', '1', '-i', '100'],
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                # Use string find instead of line iteration for better performance
                output = result.stdout
                start_idx = output.find('GPU die temperature:')
                if start_idx != -1:
                    # Extract temperature from the found position
                    temp_part = output[start_idx + len('GPU die temperature:'):].lstrip()
                    temp_str = temp_part.split()[0] if temp_part else ""
                    if temp_str:
                        return float(temp_str)
        except (subprocess.TimeoutExpired, ValueError, subprocess.SubprocessError, PermissionError):
            pass

        # Fallback to ioreg
        try:
            cmd = ['ioreg', '-r', '-c', 'IOHWSensor', '-d', '2']
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                # Use regex to find GPU temperature sensor more efficiently
                import re
                # Pattern to match GPU temperature sensor blocks
                gpu_temp_pattern = r'"type" = <temperature>.*?"current-value" = ([0-9]+)'
                # Find all temperature sensors
                matches = re.finditer(gpu_temp_pattern, result.stdout, re.DOTALL)
                for match in matches:
                    # Check if this block contains GPU reference
                    block_start = max(0, match.start() - 200)  # Look back 200 chars
                    block_end = min(len(result.stdout), match.end() + 200)  # Look forward 200 chars
                    block = result.stdout[block_start:block_end]
                    if 'GPU' in block or 'gpu' in block:
                        value = int(match.group(1))
                        temp_kelvin = value / 1000000.0
                        return temp_kelvin - 273.15
                return None
        except (subprocess.TimeoutExpired, ValueError, subprocess.SubprocessError, re.error):
            pass
        return None

    def get_fan_speeds(self) -> List[int]:
        """Get all fan speeds using multiple methods."""
        fan_speeds = []

        # Method 1: Try AppleFan class (newer Macs)
        try:
            cmd = ['ioreg', '-r', '-c', 'AppleFan', '-d', '2']
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=3)
            if result.returncode == 0:
                lines = result.stdout.split('\n')
                for line in lines:
                    if '"actual-speed"' in line:
                        try:
                            rpm = int(line.split('=')[1].strip())
                            fan_speeds.append(rpm)
                        except (ValueError, IndexError):
                            continue
        except (subprocess.TimeoutExpired, subprocess.SubprocessError):
            pass

        # Method 2: Try SMC fan keys (older Macs)
        if not fan_speeds:
            try:
                cmd = ['ioreg', '-l']
                result = subprocess.run(cmd, capture_output=True, timeout=5)
                if result.returncode == 0:
                    # Handle encoding issues by decoding with errors='ignore'
                    output = result.stdout.decode('utf-8', errors='ignore')
                    lines = output.split('\n')
                    for line in lines:
                        # Look for fan speed entries like "F0Ac" or "F1Ac"
                        if ('"F' in line and 'Ac"' in line and '=' in line) or ('fan-rpm' in line.lower()):
                            try:
                                # Extract numeric value after =
                                parts = line.split('=')
                                if len(parts) >= 2:
                                    value_str = parts[1].strip()
                                    # Remove quotes and extract number
                                    value_str = value_str.replace('"', '').replace(',', '')
                                    if value_str.isdigit():
                                        rpm = int(value_str)
                                        if rpm > 0:  # Only add valid RPM values
                                            fan_speeds.append(rpm)
                            except (ValueError, IndexError):
                                continue
            except (subprocess.TimeoutExpired, subprocess.SubprocessError):
                pass

        # Method 3: Fallback to GPU performance stats (if available)
        if not fan_speeds:
            try:
                cmd = ['ioreg', '-l']
                result = subprocess.run(cmd, capture_output=True, timeout=3)
                if result.returncode == 0:
                    # Handle encoding issues
                    output = result.stdout.decode('utf-8', errors='ignore')
                    # Look for "Fan Speed(RPM)" in GPU stats
                    if '"Fan Speed(RPM)"=' in output:
                        import re
                        matches = re.findall(r'"Fan Speed\(RPM\)"=(\d+)', output)
                        for match in matches:
                            rpm = int(match)
                            if rpm > 0:
                                fan_speeds.append(rpm)
            except (subprocess.TimeoutExpired, subprocess.SubprocessError):
                pass

        return fan_speeds if fan_speeds else [0]

    def get_cpu_frequency(self) -> Optional[int]:
        """Get current CPU frequency."""
        try:
            # Try sysctl first
            result = subprocess.run(['sysctl', '-n', 'hw.cpufrequency'],
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                freq_hz = int(result.stdout.strip())
                return freq_hz // 1000000  # Convert to MHz

            # Fallback to ioreg
            cmd = ['ioreg', '-r', '-c', 'IOHWSensor', '-d', '2']
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                lines = result.stdout.split('\n')
                for line in lines:
                    if '"cpu-frequency"' in line.lower():
                        try:
                            freq_hz = int(line.split('=')[1].strip())
                            return freq_hz // 1000000
                        except (ValueError, IndexError):
                            continue
        except (subprocess.TimeoutExpired, ValueError, subprocess.SubprocessError):
            pass
        return None

    def get_cpu_usage(self) -> float:
        """Get overall CPU usage percentage."""
        try:
            import psutil
            return psutil.cpu_percent(interval=0.1)
        except ImportError:
            # Fallback to basic calculation
            try:
                cmd = ['iostat', '-c', '2', '-n', '10']
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    lines = result.stdout.strip().split('\n')
                    for line in lines[-3:]:  # Check last few lines
                        if line.strip() and not line.startswith('cpu'):
                            parts = line.split()
                            if len(parts) >= 6:
                                user = float(parts[0])
                                sys = float(parts[2])
                                return user + sys
            except (subprocess.TimeoutExpired, ValueError, subprocess.SubprocessError):
                pass
        return 0.0

    def estimate_cpu_power(self, cpu_usage: float, cpu_freq: Optional[int]) -> float:
        """Estimate CPU power consumption based on usage and frequency."""
        base_power = CPU_POWER_CONSTANTS['idle_watts']

        if cpu_freq is None:
            # Assume base frequency if we can't read it
            freq_factor = 1.0
        else:
            # Scale power with frequency (assuming base freq is around 2000 MHz)
            freq_factor = min(cpu_freq / 2000.0, 1.5) * CPU_POWER_CONSTANTS['frequency_factor']

        # Scale power with CPU usage
        load_power = (cpu_usage / 100.0) * (CPU_POWER_CONSTANTS['max_watts'] - base_power)

        # Apply frequency scaling to load power
        estimated_power = base_power + (load_power * freq_factor * CPU_POWER_CONSTANTS['load_factor'])

        # Clamp to reasonable range
        return max(CPU_POWER_CONSTANTS['idle_watts'], min(estimated_power, CPU_POWER_CONSTANTS['max_watts']))

    def get_thermal_state(self) -> int:
        """Get system thermal state (0-3)."""
        try:
            cmd = ['ioreg', '-r', '-c', 'IOPlatformThermalProfile', '-d', '2']
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                if '"Thermal State" = 3' in result.stdout:
                    return 3
                elif '"Thermal State" = 2' in result.stdout:
                    return 2
                elif '"Thermal State" = 1' in result.stdout:
                    return 1
        except (subprocess.TimeoutExpired, subprocess.SubprocessError):
            pass
        return 0

    def get_memory_power(self) -> float:
        """Estimate memory power consumption."""
        try:
            import psutil
            mem = psutil.virtual_memory()
            # Rough estimate: 2-8W based on usage
            base_power = 2.0
            active_power = (mem.percent / 100.0) * 6.0
            return base_power + active_power
        except ImportError:
            # Default estimate
            return 4.0

    def get_gpu_power_estimate(self) -> float:
        """Estimate GPU power based on activity."""
        # This is a rough estimate based on thermal state and GPU temp
        gpu_temp = self.get_gpu_temperature()
        if gpu_temp is None:
            return 5.0  # Idle estimate

        # Simple linear model: 5-30W based on temperature
        if gpu_temp < 50:
            return 5.0
        elif gpu_temp > 85:
            return 30.0
        else:
            return 5.0 + (gpu_temp - 50) * (25.0 / 35.0)

    def log_thermal_data(self, writer: csv.writer, timestamp: str):
        """Log thermal monitoring data."""
        cpu_temp = self.get_cpu_temperature()
        gpu_temp = self.get_gpu_temperature()
        fan_speeds = self.get_fan_speeds()
        cpu_freq = self.get_cpu_frequency()
        cpu_usage = self.get_cpu_usage()
        thermal_state = self.get_thermal_state()

        # Get max fan speed
        max_fan = max(fan_speeds) if fan_speeds else 0

        # Estimate GPU activity based on temperature
        gpu_activity = 0.0
        if gpu_temp is not None and gpu_temp > 50:
            gpu_activity = min(100.0, (gpu_temp - 50) * 2.0)

        # CPU speed limit based on thermal state
        cpu_speed_limit = 100 - (thermal_state * 15)

        # Write data
        writer.writerow([
            timestamp,
            f"{cpu_temp:.1f}" if cpu_temp is not None else "0.0",
            f"{gpu_temp:.1f}" if gpu_temp is not None else "0.0",
            max_fan,
            f"{gpu_activity:.1f}",
            cpu_freq if cpu_freq is not None else "0",
            f"{cpu_usage:.1f}",
            cpu_speed_limit,
            "0",  # CPU_Plimit - not available
            "0",  # Prochots - not available
            thermal_state
        ])

    def log_power_data(self, writer: csv.writer, timestamp: str):
        """Log power monitoring data."""
        cpu_usage = self.get_cpu_usage()
        cpu_freq = self.get_cpu_frequency()

        cpu_power = self.estimate_cpu_power(cpu_usage, cpu_freq)
        gpu_power = self.get_gpu_power_estimate()
        memory_power = self.get_memory_power()

        writer.writerow([
            timestamp,
            f"{cpu_power:.1f}",
            f"{gpu_power:.1f}",
            f"{memory_power:.1f}"
        ])

    def monitor_loop(self, thermal_file: str, power_file: str, interval: float = 2.0, show_realtime: bool = False):
        """Main monitoring loop."""
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)

        # Write CSV headers
        with open(thermal_file, 'w', newline='') as tf, open(power_file, 'w', newline='') as pf:
            thermal_writer = csv.writer(tf)
            power_writer = csv.writer(pf)

            # Headers matching existing format
            thermal_writer.writerow([
                'Timestamp', 'CPU_Temp_C', 'GPU_Temp_C', 'Fan_RPM',
                'GPU_Activity_%', 'CPU_Freq_MHz', 'Kernel_Task_%',
                'CPU_Speed_Limit_%', 'CPU_Plimit', 'Prochots', 'Thermal_Level'
            ])

            power_writer.writerow([
                'Timestamp', 'CPU_Power_W', 'GPU_Power_W', 'Memory_Power_W'
            ])

            tf.flush()
            pf.flush()

            # Main loop
            # Start continuous powermetrics process with all required samplers
            powermetrics_proc = None
            try:
                powermetrics_proc = subprocess.Popen(
                    ['powermetrics', '--samplers', 'smc,cpu_power,gpu_power', '-i', str(int(interval * 1000))],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1
                )
                print("Continuous powermetrics monitoring started", file=sys.stderr)
            except (subprocess.SubprocessError, PermissionError) as e:
                print(f"Failed to start continuous powermetrics: {e}", file=sys.stderr)
                powermetrics_proc = None

            # Main loop
            while self.running:
                try:
                    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

                    # Initialize sensor values
                    cpu_temp = None
                    gpu_temp = None
                    fan_rpm = None
                    cpu_power_val = None
                    gpu_power_val = None
                    thermal_state_pm = None  # Thermal state from powermetrics

                    # Try to get data from continuous powermetrics
                    if powermetrics_proc is not None:
                        try:
                            # Accumulate powermetrics output to capture complete sensor blocks
                            import select
                            accumulated_output = ""
                            start_time = time.time()
                            timeout = 0.5  # Wait up to 0.5 seconds to accumulate data

                            while time.time() - start_time < timeout:
                                ready, _, _ = select.select([powermetrics_proc.stdout], [], [], 0.1)
                                if ready:
                                    line = powermetrics_proc.stdout.readline()
                                    if line:
                                        accumulated_output += line
                                    else:
                                        break
                                else:
                                    break

                            if accumulated_output:
                                # Parse all sensor data from accumulated output
                                lines = accumulated_output.split('\n')
                                for line in lines:
                                    line = line.strip()
                                    if not line:
                                        continue

                                    # Parse CPU temperature
                                    if 'CPU die temperature:' in line:
                                        try:
                                            temp_val = float(line.split('CPU die temperature:')[1].strip().split()[0])
                                            cpu_temp = temp_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse GPU temperature
                                    elif 'GPU die temperature:' in line:
                                        try:
                                            temp_val = float(line.split('GPU die temperature:')[1].strip().split()[0])
                                            gpu_temp = temp_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse Fan speed
                                    elif 'Fan:' in line:
                                        try:
                                            # Extract number before "rpm" or any non-numeric suffix
                                            fan_part = line.split('Fan:')[1].strip()
                                            # Remove "rpm" and other suffixes
                                            fan_part = fan_part.replace('rpm', '').replace('RPM', '').strip()
                                            # Get first number
                                            fan_num = fan_part.split()[0]
                                            fan_val = int(float(fan_num))
                                            fan_rpm = fan_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse CPU Thermal level
                                    elif 'CPU Thermal level:' in line:
                                        try:
                                            thermal_val = int(float(line.split('CPU Thermal level:')[1].strip().split()[0]))
                                            thermal_state_pm = thermal_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Fallback: Parse generic Thermal level
                                    elif 'Thermal level:' in line and 'CPU' not in line and 'GPU' not in line and 'IO' not in line:
                                        try:
                                            thermal_val = int(float(line.split('Thermal level:')[1].strip().split()[0]))
                                            thermal_state_pm = thermal_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse CPU Power - multiple patterns
                                    elif 'CPU Power:' in line:
                                        try:
                                            power_part = line.split('CPU Power:')[1].strip()
                                            power_part = power_part.replace('W', '').strip()
                                            power_val = float(power_part.split()[0])
                                            cpu_power_val = power_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse CPU package power
                                    elif 'CPU package power:' in line:
                                        try:
                                            power_part = line.split('CPU package power:')[1].strip()
                                            power_part = power_part.replace('W', '').strip()
                                            power_val = float(power_part.split()[0])
                                            cpu_power_val = power_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse Package Power (Intel systems)
                                    elif 'Package Power:' in line and ('CPU' in line or 'Processor' in line):
                                        try:
                                            power_part = line.split('Package Power:')[1].strip()
                                            power_part = power_part.replace('W', '').strip()
                                            power_val = float(power_part.split()[0])
                                            cpu_power_val = power_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse GPU Power - multiple patterns
                                    elif 'GPU Power:' in line:
                                        try:
                                            power_part = line.split('GPU Power:')[1].strip()
                                            # Remove 'W' suffix and extract number
                                            power_part = power_part.replace('W', '').strip()
                                            power_val = float(power_part.split()[0])
                                            gpu_power_val = power_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse GPU package power
                                    elif 'GPU package power:' in line:
                                        try:
                                            power_part = line.split('GPU package power:')[1].strip()
                                            power_part = power_part.replace('W', '').strip()
                                            power_val = float(power_part.split()[0])
                                            gpu_power_val = power_val
                                        except (ValueError, IndexError):
                                            pass
                                    # Parse generic GPU power patterns
                                    elif 'Package Power:' in line and ('GPU' in line or 'Graphics' in line):
                                        try:
                                            power_part = line.split('Package Power:')[1].strip()
                                            power_part = power_part.replace('W', '').strip()
                                            power_val = float(power_part.split()[0])
                                            gpu_power_val = power_val
                                        except (ValueError, IndexError):
                                            pass
                        except Exception as e:
                            print(f"Error reading powermetrics: {e}", file=sys.stderr)

                    # Fallback to individual methods if needed
                    if cpu_temp is None:
                        cpu_temp = self.get_cpu_temperature()
                    if gpu_temp is None:
                        gpu_temp = self.get_gpu_temperature()
                    if fan_rpm is None:
                        fan_speeds = self.get_fan_speeds()
                        fan_rpm = max(fan_speeds) if fan_speeds else 0
                    if cpu_power_val is None:
                        cpu_freq = self.get_cpu_frequency()
                        cpu_usage = self.get_cpu_usage()
                        cpu_power_val = self.estimate_cpu_power(cpu_usage, cpu_freq)
                    if gpu_power_val is None:
                        gpu_power_val = self.get_gpu_power_estimate()

                    # Get other metrics
                    cpu_freq = self.get_cpu_frequency()
                    cpu_usage = self.get_cpu_usage()
                    # Use powermetrics thermal state if available, otherwise fallback
                    if thermal_state_pm is not None:
                        thermal_state = thermal_state_pm
                    else:
                        thermal_state = self.get_thermal_state()
                    memory_power = self.get_memory_power()

                    # Log to CSV files
                    self.log_thermal_data(thermal_writer, timestamp)
                    self.log_power_data(power_writer, timestamp)

                    tf.flush()
                    pf.flush()

                    # Show real-time metrics if requested
                    if show_realtime:
                        gpu_activity = 0.0
                        if gpu_temp is not None and gpu_temp > 50:
                            gpu_activity = min(100.0, (gpu_temp - 50) * 2.0)

                        cpu_temp_str = f"{cpu_temp:.1f}°C" if cpu_temp is not None else "N/A"
                        gpu_temp_str = f"{gpu_temp:.1f}°C" if gpu_temp is not None else "N/A"
                        cpu_freq_str = f"{cpu_freq}MHz" if cpu_freq is not None else "N/A"

                        print(f"[{timestamp}] CPU Temp: {cpu_temp_str} | CPU Freq: {cpu_freq_str} | CPU Load: {cpu_usage:.1f}% | CPU Power: {cpu_power_val:.1f}W | "
                              f"GPU Temp: {gpu_temp_str} | GPU Load: {gpu_activity:.1f}% | GPU Power: {gpu_power_val:.1f}W | "
                              f"Fan Speed: {fan_rpm} RPM | Thermal Level: {thermal_state}",
                              flush=True)

                    time.sleep(interval)

                except Exception as e:
                    print(f"Error in monitoring loop: {e}", file=sys.stderr)
                    time.sleep(interval)

            # Cleanup powermetrics process
            if powermetrics_proc is not None:
                powermetrics_proc.terminate()
                try:
                    powermetrics_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    powermetrics_proc.kill()
                print("Continuous powermetrics monitoring stopped", file=sys.stderr)

        print("Monitoring stopped.", file=sys.stderr)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description='macOS Hardware Monitor')
    parser.add_argument('--thermal-log', required=True, help='Thermal log file path')
    parser.add_argument('--power-log', required=True, help='Power log file path')
    parser.add_argument('--interval', type=float, default=2.0, help='Sampling interval in seconds')
    parser.add_argument('--show-realtime', action='store_true', help='Show real-time monitoring output')

    args = parser.parse_args()

    monitor = MacOSMonitor()
    monitor.monitor_loop(args.thermal_log, args.power_log, args.interval, args.show_realtime)


if __name__ == '__main__':
    main()