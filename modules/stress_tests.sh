#!/bin/bash

# ==============================================================================
# 压力测试模块 - CPU、GPU、内存、磁盘的压力测试函数
# ==============================================================================

start_cpu_stress() {
    log "${CYAN}--- [启动] CPU 100% 压力测试 ---${NC}"
    CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    THREADS=$((CORES * 2))
    touch /tmp/stress_cpu_run
    (
        for i in $(seq 1 $THREADS); do
            while [ -f /tmp/stress_cpu_run ]; do
                openssl speed -elapsed -evp aes-256-cbc > /dev/null 2>&1
            done &
        done
        wait
    ) & CPU_PID=$!
}

stop_cpu_stress() {
    log "${YELLOW}--- [停止] CPU 压力测试 ---${NC}"
    rm -f /tmp/stress_cpu_run
    pkill -9 openssl 2>/dev/null
    kill -9 $CPU_PID 2>/dev/null
}

# GPU stress using Swift Metal Compute Shader (pure GPU, minimal CPU dependency)
start_gpu_stress() {
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    SWIFT_FILE="$SCRIPT_DIR/../gpu_stress_test.swift"

    if [ -f "$SWIFT_FILE" ]; then
        log "${CYAN}--- [启动] GPU 高负载运算测试 (原生 Metal Compute Shader) ---${NC}"

        # Ensure we have a clean compilation environment
        GPU_BIN="$SCRIPT_DIR/../gpu_stress_bin_$$"
        rm -f "$GPU_BIN"

        # Ensure proper environment for Swift compilation
        export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
        export SDKROOT=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "")

        # Compile with full path and proper environment (verbose for debugging)
        if swiftc -v "$SWIFT_FILE" -o "$GPU_BIN" 2>/tmp/swift_compile_error.$$; then
            if [ -f "$GPU_BIN" ]; then
                touch /tmp/stress_gpu_run
                (
                    # Run multiple GPU stress instances to fully utilize GPU
                    # This is pure GPU compute with minimal CPU dependency
                    for i in 1 2 3 4; do
                        while [ -f /tmp/stress_gpu_run ]; do
                            "$GPU_BIN" >/dev/null 2>&1
                        done &
                    done
                    wait
                ) & GPU_PID=$!
                log "${GREEN}[GPU] 使用原生 Metal Compute Shader 测试 (最小CPU依赖)${NC}"
                return 0
            else
                log "${RED}[GPU] 编译成功但二进制文件未生成${NC}"
                cat /tmp/swift_compile_error.$$ >&2
            fi
        else
            log "${RED}[GPU] Swift 编译失败:${NC}"
            cat /tmp/swift_compile_error.$$
        fi

        # Cleanup compilation artifacts
        rm -f "$GPU_BIN" /tmp/swift_compile_error.$$ "$SCRIPT_DIR/../gpu_stress_bin_"*
    else
        log "${RED}[GPU] 未找到 gpu_stress_test.swift 文件，跳过 GPU 测试${NC}"
    fi

    return 1
}

stop_gpu_stress() {
    log "${YELLOW}--- [停止] GPU 压力测试 ---${NC}"
    rm -f /tmp/stress_gpu_run
    kill -9 $GPU_PID 2>/dev/null
    pkill -9 -f "gpu_stress_bin" 2>/dev/null
    rm -f /tmp/gpu_stress_bin_* 2>/dev/null
}

start_mem_stress() {
    log "${CYAN}--- [启动] 内存分配测试 ---${NC}"
    MEM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')
    MEM_STRESS=$((MEM_GB / 4))
    [ $MEM_STRESS -lt 1 ] && MEM_STRESS=1
    [ $MEM_STRESS -gt 4 ] && MEM_STRESS=4
    (
        for i in $(seq 1 $MEM_STRESS); do
            dd if=/dev/zero of=/tmp/mem_stress_$i bs=1m count=1024 2>/dev/null &
        done
        wait
        rm -f /tmp/mem_stress_* 2>/dev/null
    ) & MEM_PID=$!
}

start_disk_stress() {
    log "${CYAN}--- [启动] 硬盘 I/O 压力测试 ---${NC}"
    touch /tmp/stress_disk_run
    (
        while [ -f /tmp/stress_disk_run ]; do
            # Write 2GB file to create sustained I/O pressure
            dd if=/dev/zero of=/tmp/disk_stress_test bs=1m count=2048 2>/dev/null
            # Read the file
            dd if=/tmp/disk_stress_test of=/dev/null bs=1m 2>/dev/null
            rm -f /tmp/disk_stress_test 2>/dev/null
        done
    ) & DISK_PID=$!
}

stop_disk_stress() {
    log "${YELLOW}--- [停止] 硬盘 I/O 压力测试 ---${NC}"
    rm -f /tmp/stress_disk_run
    kill -9 $DISK_PID 2>/dev/null
    pkill -9 -f "dd if=/dev/zero of=/tmp/disk_stress_test" 2>/dev/null
    rm -f /tmp/disk_stress_test 2>/dev/null
}