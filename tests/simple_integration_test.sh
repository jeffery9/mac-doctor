#!/bin/bash

# Simple integration test for Python monitoring

echo "Testing Python monitoring integration..."

# Test 1: Check if PYTHON_MONITOR variable is set correctly
if ./stress_no_gltest.sh --python-monitor -d 1 2>&1 | grep -q "DEBUG: PYTHON_MONITOR=true"; then
    echo "✓ PYTHON_MONITOR variable set correctly"
else
    echo "✗ PYTHON_MONITOR variable not set correctly"
    exit 1
fi

# Test 2: Check if Python monitoring mode is activated
if printf "2\n" | ./stress_no_gltest.sh --python-monitor -d 5 2>&1 | grep -q "Python监控模式"; then
    echo "✓ Python monitoring mode activated"
else
    echo "✗ Python monitoring mode not activated"
    exit 1
fi

echo "All tests passed!"