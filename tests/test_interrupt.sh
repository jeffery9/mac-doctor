#!/bin/bash

# Test interrupt handling
echo "=== 测试Ctrl+C中断处理 ==="
echo "测试将在5秒后自动发送Ctrl+C信号"
echo ""

# Start the stress test in background
echo "2" | ./stress_no_gltest.sh -d 30 > /tmp/interrupt_test.log 2>&1 &
TEST_PID=$!

# Wait 5 seconds
echo "等待5秒..."
sleep 5

# Send SIGINT (Ctrl+C)
echo "发送中断信号..."
kill -INT $TEST_PID 2>/dev/null

# Wait for process to finish
wait $TEST_PID 2>/dev/null
EXIT_CODE=$?

echo ""
echo "=== 测试结果 ==="
echo "退出码: $EXIT_CODE"
echo ""

# Check if cleanup was performed
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

# Show last 10 lines
echo ""
echo "最后10行输出:"
tail -10 /tmp/interrupt_test.log

# Cleanup
rm -f /tmp/interrupt_test.log

echo ""
echo "=== 测试完成 ==="