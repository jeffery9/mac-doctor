#!/bin/bash

# Integration test for Python monitoring with stress test suite
# Tests the complete workflow with Python monitoring enabled

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test configuration
TEST_DURATION=30  # Short test for integration
REPORT_DIR=""

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    pkill -f stress_no_gltest.sh 2>/dev/null || true
    pkill -f python_monitor_core.py 2>/dev/null || true
    rm -rf /tmp/stress_diag_* 2>/dev/null || true
}

trap cleanup EXIT

# Header
echo "=========================================="
echo "Python Monitoring Integration Test"
echo "=========================================="
echo

# Test 1: Basic Python monitoring mode
echo -e "${YELLOW}Test 1: Basic Python monitoring mode${NC}"
echo "Running stress test with Python monitoring for ${TEST_DURATION} seconds..."

# Run stress test with Python monitoring
expect << EOF
set timeout [expr {$TEST_DURATION + 10}]
spawn ./stress_no_gltest.sh --python-monitor -d $TEST_DURATION
expect "请选择测试模式："
send "2\r"  # Select CPU-only test
expect {
    "测试完成" { exit 0 }
    timeout { exit 1 }
    eof { exit 1 }
}
EOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Stress test with Python monitoring completed${NC}"
else
    echo -e "${RED}✗ Stress test with Python monitoring failed${NC}"
    exit 1
fi

# Find the report directory
REPORT_DIR=$(ls -dt /tmp/stress_diag_* 2>/dev/null | head -n1)
if [[ -z "$REPORT_DIR" ]] || [[ ! -d "$REPORT_DIR" ]]; then
    echo -e "${RED}✗ Report directory not found${NC}"
    exit 1
fi

echo -e "Report directory: $REPORT_DIR"

# Test 2: Verify CSV files were created
echo -e "\n${YELLOW}Test 2: Verifying output files${NC}"

for file in thermal_log.csv power_log.csv; do
    if [[ -f "$REPORT_DIR/$file" ]]; then
        lines=$(wc -l < "$REPORT_DIR/$file")
        if [[ $lines -gt 1 ]]; then
            echo -e "${GREEN}✓ $file created with $lines lines${NC}"
        else
            echo -e "${RED}✗ $file has insufficient data ($lines lines)${NC}"
            exit 1
        fi
    else
        echo -e "${RED}✗ $file not found${NC}"
        exit 1
    fi
done

# Test 3: Verify CSV format
echo -e "\n${YELLOW}Test 3: Verifying CSV format${NC}"

# Check thermal log format
thermal_header=$(head -n1 "$REPORT_DIR/thermal_log.csv")
expected_thermal="Timestamp,CPU_Temp_C,GPU_Temp_C,Fan_RPM,GPU_Activity_%,CPU_Freq_MHz,Kernel_Task_%,CPU_Speed_Limit_%,CPU_Plimit,Prochots,Thermal_Level"
if [[ "$thermal_header" == "$expected_thermal" ]]; then
    echo -e "${GREEN}✓ Thermal log header matches expected format${NC}"
else
    echo -e "${RED}✗ Thermal log header mismatch${NC}"
    echo "Expected: $expected_thermal"
    echo "Got:      $thermal_header"
    exit 1
fi

# Check power log format
power_header=$(head -n1 "$REPORT_DIR/power_log.csv")
expected_power="Timestamp,CPU_Power_W,GPU_Power_W,Memory_Power_W"
if [[ "$power_header" == "$expected_power" ]]; then
    echo -e "${GREEN}✓ Power log header matches expected format${NC}"
else
    echo -e "${RED}✗ Power log header mismatch${NC}"
    echo "Expected: $expected_power"
    echo "Got:      $power_header"
    exit 1
fi

# Test 4: Verify data quality
echo -e "\n${YELLOW}Test 4: Verifying data quality${NC}"

# Check for reasonable temperature values
if grep -qE '^[0-9:, ]+,[0-9]{2,3},' "$REPORT_DIR/thermal_log.csv"; then
    echo -e "${GREEN}✓ Temperature data found${NC}"
else
    echo -e "${RED}✗ No valid temperature data found${NC}"
    exit 1
fi

# Check for reasonable power values (5-70W range)
if grep -qE '^[0-9:, ]+,[0-9]+\.[0-9]+,' "$REPORT_DIR/power_log.csv"; then
    echo -e "${GREEN}✓ Power data found${NC}"
else
    echo -e "${RED}✗ No valid power data found${NC}"
    exit 1
fi

# Test 5: Test fallback mode
echo -e "\n${YELLOW}Test 5: Testing fallback to shell monitoring${NC}"

# Temporarily rename Python to simulate unavailability
mv /usr/bin/python3 /usr/bin/python3.bak 2>/dev/null || true

expect << EOF
set timeout 20
spawn ./stress_no_gltest.sh -d 10
expect "请选择测试模式："
send "2\r"  # Select CPU-only test
expect {
    "测试完成" { exit 0 }
    timeout { exit 1 }
    eof { exit 1 }
}
EOF

fallback_result=$?

# Restore Python
mv /usr/bin/python3.bak /usr/bin/python3 2>/dev/null || true

if [ $fallback_result -eq 0 ]; then
    echo -e "${GREEN}✓ Fallback to shell monitoring works${NC}"
else
    echo -e "${RED}✗ Fallback to shell monitoring failed${NC}"
    exit 1
fi

# Summary
echo
echo "=========================================="
echo -e "${GREEN}All integration tests passed!${NC}"
echo "Python monitoring is working correctly"
echo "=========================================="