#!/bin/bash

# Test script for Python monitoring integration
# Validates Python monitor functionality and data format compatibility

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Test function
run_test() {
    local test_name="$1"
    local test_cmd="$2"

    echo -n "Testing $test_name... "
    if eval "$test_cmd"; then
        echo -e "${GREEN}PASSED${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAILED${NC}"
        ((TESTS_FAILED++))
    fi
}

# Header
echo "==================================="
echo "Python Monitoring Integration Tests"
echo "==================================="
echo

# Test 1: Check Python availability
run_test "Python 3 availability" "command -v python3 >/dev/null 2>&1"

# Test 2: Check Python monitor script exists
run_test "Python monitor script exists" "[[ -f python_monitor_core.py ]]"

# Test 3: Check Python syntax
run_test "Python syntax validation" "python3 -m py_compile python_monitor_core.py"

# Test 4: Check required modules
run_test "Required Python modules" "python3 -c 'import sys, csv, json, subprocess, argparse, signal'"

# Test 5: Check shell bridge module
run_test "Shell bridge module exists" "[[ -f modules/monitoring_python.sh ]]"

# Test 6: Check config module
run_test "Python config module exists" "[[ -f modules/config_python.sh ]]"

# Test 7: Test Python monitor help
run_test "Python monitor help" "python3 python_monitor_core.py --help >/dev/null 2>&1"

# Test 8: Test thermal data collection (brief)
echo -n "Testing thermal data collection... "
if python3 python_monitor_core.py --thermal-log /tmp/test_thermal.csv --power-log /tmp/test_power.csv --interval 1 &
then
    PID=$!
    sleep 3
    if kill $PID 2>/dev/null && [[ -f /tmp/test_thermal.csv ]] && [[ $(wc -l < /tmp/test_thermal.csv) -gt 1 ]]; then
        echo -e "${GREEN}PASSED${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAILED${NC}"
        ((TESTS_FAILED++))
    fi
    rm -f /tmp/test_thermal.csv /tmp/test_power.csv
else
    echo -e "${RED}FAILED${NC}"
    ((TESTS_FAILED++))
fi

# Test 9: Test CSV format compatibility
echo -n "Testing CSV format compatibility... "
python3 python_monitor_core.py --thermal-log /tmp/test_thermal.csv --power-log /tmp/test_power.csv --interval 0.5 &
PID=$!
sleep 3
kill $PID 2>/dev/null
sleep 1  # Give time for file write to complete

if [[ -f /tmp/test_thermal.csv ]] && [[ -f /tmp/test_power.csv ]]; then
    # Check headers
    thermal_header=$(head -n1 /tmp/test_thermal.csv | tr -d '\r')
    power_header=$(head -n1 /tmp/test_power.csv | tr -d '\r')

    expected_thermal="Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Activity_%,CPU_Freq_MHz,Kernel_Task_%,CPU_Speed_Limit_%,CPU_Plimit,Prochots,Thermal_Level"
    expected_power="Timestamp,CPU_Power_W,GPU_Power_W,Memory_Power_W"

    if [[ "$thermal_header" == "$expected_thermal" ]] && [[ "$power_header" == "$expected_power" ]]; then
        echo -e "${GREEN}PASSED${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAILED${NC} (header mismatch)"
        echo "  Expected thermal: $expected_thermal"
        echo "  Actual thermal:   $thermal_header"
        echo "  Expected power: $expected_power"
        echo "  Actual power:   $power_header"
        ((TESTS_FAILED++))
    fi
else
    echo -e "${RED}FAILED${NC} (files not created)"
    ((TESTS_FAILED++))
fi
rm -f /tmp/test_thermal.csv /tmp/test_power.csv

# Test 10: Integration test with main script
echo -n "Testing integration with main script... "
if printf "2\n" | ./stress_no_gltest.sh --python-monitor -d 5 2>&1 | grep -q "Python监控模式"; then
    echo -e "${GREEN}PASSED${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}FAILED${NC}"
    ((TESTS_FAILED++))
fi

# Summary
echo
echo "==================================="
echo "Test Summary:"
echo -e "  Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "  Failed: ${RED}$TESTS_FAILED${NC}"
echo "==================================="

# Exit with appropriate code
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi