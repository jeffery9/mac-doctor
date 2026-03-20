#!/bin/bash

# Test Ctrl+C interrupt handling
echo "=== 测试Ctrl+C中断功能 ==="
echo ""
echo "测试将在5秒后自动发送Ctrl+C信号"
echo "请观察是否正常中断并清理"
echo ""

# Start the stress test in background
echo "启动压力测试..."
cd "$(dirname "$0")/.."

echo "2" | ./stress_no_gltest.sh -d 60 > /tmp/interrupt_test.log 2>&1 &
TEST_PID=$!

# Wait 5 seconds
echo "等待5秒..."
sleep 5

# Send SIGINT (Ctrl+C)
echo "发送Ctrl+C信号 (SIGINT)..."
kill -INT $TEST_PID 2>/dev/null

# Wait for process to finish
wait $TEST_PID 2>/dev/null
EXIT_CODE=$?

echo ""
echo "=== 中断测试结果 ==="
echo "退出码: $EXIT_CODE (0=正常, 130=Ctrl+C, 其他=异常)"
echo ""

# Check if interrupt was handled properly
echo "检查中断处理情况:"

if grep -q "检测到提前终止信号" /tmp/interrupt_test.log; then
    echo "✓ 检测到中断信号"
else
    echo "✗ 未检测到中断信号"
fi

if grep -q "停止所有负载进程" /tmp/interrupt_test.log; then
    echo "✓ 执行了清理操作"
else
    echo "✗ 未执行清理操作"
fi

if grep -q "诊断报告生成" /tmp/interrupt_test.log; then
    echo "✓ 生成了诊断报告"
else
    echo "✗ 未生成诊断报告"
fi

# Show relevant output
echo ""
echo "关键输出片段:"
grep -E "(中断|停止|清理|完成)" /tmp/interrupt_test.log | tail -10

# Check for common issues
echo ""
echo "=== 问题检查 ==="

if grep -q "Killed" /tmp/interrupt_test.log; then
    echo "⚠  检测到强制终止信号"
fi

if grep -q "Error" /tmp/interrupt_test.log; then
    echo "⚠  检测到错误信息"
fi

# Test immediate responsiveness
echo ""
echo "=== 响应速度测试 ==="
start_time=$(date +%s)
echo "2" | timeout 2 ./stress_no_gltest.sh -d 60 > /tmp/quick_test.log 2>&1 &
QUICK_PID=$!
sleep 1
kill -INT $QUICK_PID 2>/dev/null
wait $QUICK_PID 2>/dev/null
end_time=$(date +%s)
response_time=$((end_time - start_time))
echo "响应时间: ${response_time}秒 (期望: <3秒)"

echo ""
echo "=== 建议改进 ==="
if [ "$response_time" -gt 3 ]; then
    echo "⚠  响应时间较长，需要优化中断处理"
fi

if [ "$EXIT_CODE" -ne 0 ] && [ "$EXIT_CODE" -ne 130 ]; then
    echo "⚠  异常退出码，需要检查错误处理"
fi

# Cleanup
rm -f /tmp/interrupt_test.log /tmp/quick_test.log /tmp/stress_early_stop.flag

echo ""
echo "${GREEN}Ctrl+C中断功能测试完成！${NC}"