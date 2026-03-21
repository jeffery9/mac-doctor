#!/bin/bash

# Python monitoring configuration

# Python interpreter to use
PYTHON_CMD="${PYTHON_CMD:-python3}"

# Python monitoring settings
PYTHON_MONITOR_INTERVAL="${PYTHON_MONITOR_INTERVAL:-2}"
PYTHON_LOG_LEVEL="${PYTHON_LOG_LEVEL:-INFO}"

# Fallback settings
PYTHON_FALLBACK_ON_ERROR="${PYTHON_FALLBACK_ON_ERROR:-true}"
PYTHON_STARTUP_TIMEOUT="${PYTHON_STARTUP_TIMEOUT:-5}"

# Python script path
PYTHON_MONITOR_SCRIPT="$SCRIPT_DIR/../python_monitor_core.py"

# Check Python environment
check_python_environment() {
    local errors=0

    # Check Python version (need 3.6+)
    if ! $PYTHON_CMD -c "import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)" 2>/dev/null; then
        log_message "Python 3.6+ required for monitoring"
        ((errors++))
    fi

    # Check required system commands
    local required_cmds=("ioreg" "sysctl")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_message "Required command '$cmd' not found"
            ((errors++))
        fi
    done

    # Check optional commands
    if ! command -v osx-cpu-temp &> /dev/null; then
        log_message "Warning: osx-cpu-temp not found, temperature accuracy may be reduced"
    fi

    return $errors
}

# Install Python dependencies if needed
install_python_deps() {
    log_message "Checking Python dependencies..."

    # Try to install psutil if missing
    if ! $PYTHON_CMD -c "import psutil" 2>/dev/null; then
        log_message "Installing psutil for better CPU monitoring..."
        if command -v pip3 &> /dev/null; then
            pip3 install --user psutil 2>/dev/null || true
        fi
    fi

    # Try to install osx-cpu-temp if missing
    if ! command -v osx-cpu-temp &> /dev/null; then
        log_message "osx-cpu-temp not available, using ioreg fallback"
    fi
}

# Validate Python monitoring setup
validate_python_setup() {
    log_message "Validating Python monitoring setup..."

    # Check environment
    if ! check_python_environment; then
        log_message "Python environment check failed"
        return 1
    fi

    # Check script exists
    if [[ ! -f "$PYTHON_MONITOR_SCRIPT" ]]; then
        log_message "Python monitor script not found: $PYTHON_MONITOR_SCRIPT"
        return 1
    fi

    # Test script syntax
    if ! $PYTHON_CMD -m py_compile "$PYTHON_MONITOR_SCRIPT" 2>/dev/null; then
        log_message "Python monitor script has syntax errors"
        return 1
    fi

    # Install dependencies
    install_python_deps

    log_message "Python monitoring setup validated successfully"
    return 0
}