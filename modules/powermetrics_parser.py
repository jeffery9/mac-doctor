#!/usr/bin/env python3
"""
Powermetrics output parser for macOS performance monitoring
Optimized for continuous data acquisition and processing
"""

import subprocess
import re
import time
import json
from typing import Dict, Optional, Tuple


class PowermetricsParser:
    """Parser for powermetrics output with optimized data extraction"""

    def __init__(self):
        self.smc_patterns = {
            'cpu_temp': re.compile(r'CPU die temperature:\s+([0-9.]+)\s+C'),
            'gpu_temp': re.compile(r'GPU die temperature:\s+([0-9.]+)\s+C'),
            'fan_rpm': re.compile(r'Fan:\s+([0-9.]+)\s+rpm'),
            'cpu_plimit': re.compile(r'CPU Plimit:\s+([0-9.]+)'),
            'gpu_plimit': re.compile(r'GPU Plimit \(Int\):\s+([0-9.]+)'),
            'prochots': re.compile(r'Number of prochots:\s+([0-9]+)'),
            'thermal_level': re.compile(r'CPU Thermal level:\s+([0-9]+)'),
        }

        self.power_patterns = {
            'cpu_power': re.compile(r'CPU Power:\s+([0-9.]+)\s+W'),
            'cpu_package_power': re.compile(r'CPU package power:\s+([0-9.]+)\s+W'),
            'gpu_power': re.compile(r'GPU Power:\s+([0-9.]+)\s+W'),
            'gpu_package_power': re.compile(r'GPU package power:\s+([0-9.]+)\s+W'),
            'memory_power': re.compile(r'Memory Power:\s+([0-9.]+)\s+W'),
            'dram_power': re.compile(r'DRAM Power:\s+([0-9.]+)\s+W'),
            'package_power': re.compile(r'Package Power:\s+([0-9.]+)\s+W'),
        }

        self.freq_patterns = {
            'cpu_avg_freq': re.compile(r'CPU average frequency:\s+([0-9.]+)\s+MHz'),
            'e_cluster_freq': re.compile(r'E cluster frequency:\s+([0-9.]+)\s+MHz'),
            'cpu_core_freq': re.compile(r'CPU[0-9]+:\s+.*frequency:\s+([0-9.]+)\s+MHz'),
        }

    def run_powermetrics(self, samplers: str, sample_duration: int = 300) -> Optional[str]:
        """Run powermetrics with specified samplers and return output"""
        try:
            cmd = ['powermetrics', '-n', '1', '-i', str(sample_duration), '--samplers', samplers]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if result.returncode == 0 and result.stdout:
                return result.stdout
            return None
        except (subprocess.TimeoutExpired, subprocess.SubprocessError):
            return None

    def extract_smc_data(self, output: str) -> Dict[str, float]:
        """Extract SMC sensor data from powermetrics output"""
        data = {}

        # Temperature data
        cpu_temp_match = self.smc_patterns['cpu_temp'].search(output)
        if cpu_temp_match:
            data['cpu_temp'] = float(cpu_temp_match.group(1))

        gpu_temp_match = self.smc_patterns['gpu_temp'].search(output)
        if gpu_temp_match:
            data['gpu_temp'] = float(gpu_temp_match.group(1))

        # Fan data
        fan_match = self.smc_patterns['fan_rpm'].search(output)
        if fan_match:
            data['fan_rpm'] = int(float(fan_match.group(1)))

        # Power limit data
        plimit_match = self.smc_patterns['cpu_plimit'].search(output)
        if plimit_match:
            data['cpu_plimit'] = float(plimit_match.group(1))

        # Prochots
        prochots_match = self.smc_patterns['prochots'].search(output)
        if prochots_match:
            data['prochots'] = int(prochots_match.group(1))

        # Thermal level
        thermal_match = self.smc_patterns['thermal_level'].search(output)
        if thermal_match:
            data['thermal_level'] = int(thermal_match.group(1))

        return data

    def extract_power_data(self, output: str) -> Dict[str, float]:
        """Extract power consumption data from powermetrics output"""
        data = {}

        # CPU power
        cpu_power_match = self.power_patterns['cpu_power'].search(output)
        if cpu_power_match:
            data['cpu_power'] = float(cpu_power_match.group(1))
        else:
            # Try alternative pattern
            cpu_pkg_match = self.power_patterns['cpu_package_power'].search(output)
            if cpu_pkg_match:
                data['cpu_power'] = float(cpu_pkg_match.group(1))
            else:
                pkg_match = self.power_patterns['package_power'].search(output)
                if pkg_match:
                    data['cpu_power'] = float(pkg_match.group(1))

        # GPU power
        gpu_power_match = self.power_patterns['gpu_power'].search(output)
        if gpu_power_match:
            data['gpu_power'] = float(gpu_power_match.group(1))
        else:
            gpu_pkg_match = self.power_patterns['gpu_package_power'].search(output)
            if gpu_pkg_match:
                data['gpu_power'] = float(gpu_pkg_match.group(1))

        # Memory power
        mem_power_match = self.power_patterns['memory_power'].search(output)
        if mem_power_match:
            data['memory_power'] = float(mem_power_match.group(1))
        else:
            dram_match = self.power_patterns['dram_power'].search(output)
            if dram_match:
                data['memory_power'] = float(dram_match.group(1))

        return data

    def extract_frequency_data(self, output: str) -> Dict[str, float]:
        """Extract CPU frequency data from powermetrics output"""
        data = {}

        # Try different frequency patterns
        freq_match = self.freq_patterns['cpu_avg_freq'].search(output)
        if freq_match:
            data['cpu_frequency'] = float(freq_match.group(1))
        else:
            e_cluster_match = self.freq_patterns['e_cluster_freq'].search(output)
            if e_cluster_match:
                data['cpu_frequency'] = float(e_cluster_match.group(1))
            else:
                # Extract average from all cores
                core_freqs = []
                for match in self.freq_patterns['cpu_core_freq'].findall(output):
                    core_freqs.append(float(match))
                if core_freqs:
                    data['cpu_frequency'] = sum(core_freqs) / len(core_freqs)

        return data

    def get_sensor_data(self) -> Tuple[Dict[str, float], bool]:
        """Get comprehensive sensor data (temperature, fan, etc.)"""
        output = self.run_powermetrics('smc', 300)
        if output:
            data = self.extract_smc_data(output)
            # Add frequency data if available
            freq_data = self.extract_frequency_data(output)
            data.update(freq_data)
            return data, True
        return {}, False

    def get_power_data(self) -> Tuple[Dict[str, float], bool]:
        """Get power consumption data"""
        output = self.run_powermetrics('cpu_power,gpu_power', 300)
        if output:
            data = self.extract_power_data(output)
            return data, True
        return {}, False

    def get_combined_data(self) -> Tuple[Dict[str, float], bool]:
        """Get both sensor and power data efficiently"""
        # First try to get all data in one call
        output = self.run_powermetrics('smc,cpu_power,gpu_power', 300)
        if output:
            sensor_data = self.extract_smc_data(output)
            power_data = self.extract_power_data(output)
            freq_data = self.extract_frequency_data(output)

            # Combine all data
            combined_data = {}
            combined_data.update(sensor_data)
            combined_data.update(power_data)
            combined_data.update(freq_data)

            return combined_data, True

        # Fallback to separate calls
        sensor_data, sensor_ok = self.get_sensor_data()
        power_data, power_ok = self.get_power_data()

        if sensor_ok or power_ok:
            combined_data = {}
            combined_data.update(sensor_data)
            combined_data.update(power_data)
            return combined_data, True

        return {}, False


def main():
    """Test the powermetrics parser"""
    parser = PowermetricsParser()

    print("Testing SMC sensor data extraction...")
    sensor_data, ok = parser.get_sensor_data()
    if ok:
        print(f"Sensor data: {json.dumps(sensor_data, indent=2, ensure_ascii=False)}")
    else:
        print("Failed to get sensor data")

    print("\nTesting power data extraction...")
    power_data, ok = parser.get_power_data()
    if ok:
        print(f"Power data: {json.dumps(power_data, indent=2, ensure_ascii=False)}")
    else:
        print("Failed to get power data")

    print("\nTesting combined data extraction...")
    combined_data, ok = parser.get_combined_data()
    if ok:
        print(f"Combined data: {json.dumps(combined_data, indent=2, ensure_ascii=False)}")
    else:
        print("Failed to get combined data")


if __name__ == "__main__":
    main()