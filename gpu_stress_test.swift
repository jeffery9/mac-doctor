import Metal
import Foundation

guard let device = MTLCreateSystemDefaultDevice() else {
    print("No Metal device found.")
    exit(1)
}

print("Using Metal device: \(device.name)")
guard let commandQueue = device.makeCommandQueue() else { exit(1) }

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

kernel void spin(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id);
    // Heavy math loop to stress ALU
    for (int i = 0; i < 10000; i++) {
        x = sin(x) * cos(x) + tan(x);
        x = sqrt(abs(x)) + pow(x, 2.5);
    }
    out[id] = x;
}
"""

let library = try! device.makeLibrary(source: shaderSource, options: nil)
guard let function = library.makeFunction(name: "spin") else { exit(1) }
let pipelineState = try! device.makeComputePipelineState(function: function)

let elementCount = 1000000 // 1 million threads
let buffer = device.makeBuffer(length: elementCount * MemoryLayout<Float>.size, options: .storageModeShared)!

print("Starting GPU stress loop...")
while true {
    guard let commandBuffer = commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { break }
    
    encoder.setComputePipelineState(pipelineState)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    
    let gridSize = MTLSizeMake(elementCount, 1, 1)
    let threadGroupSize = MTLSizeMake(pipelineState.maxTotalThreadsPerThreadgroup, 1, 1)
    
    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
    encoder.endEncoding()
    
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}
