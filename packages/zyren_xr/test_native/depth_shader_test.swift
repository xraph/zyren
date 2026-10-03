import Foundation
import Metal

@main
struct DepthShaderTest {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A native Metal device is required.")
        }
        let library = try device.makeLibrary(source: XrDepthShader.source, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "depthVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "sceneDepth")
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let state = MTLDepthStencilDescriptor()
        state.depthCompareFunction = .always
        state.isDepthWriteEnabled = true
        let depthState = device.makeDepthStencilState(descriptor: state)!
        func texture(_ format: MTLPixelFormat, _ render: Bool = false) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: 4, height: 2, mipmapped: false)
            descriptor.usage = render ? .renderTarget : .shaderRead
            descriptor.storageMode = render ? .private : .shared
            return device.makeTexture(descriptor: descriptor)!
        }
        let metres = texture(.r32Float), confidence = texture(.r8Uint)
        let result = texture(.depth32Float, true)
        var distances: [Float] = [1, 2, 0, .nan, -1, 20, 0.05, 1]
        var qualities: [UInt8] = [2, 1, 2, 2, 2, 2, 2, 0]
        let region = MTLRegionMake2D(0, 0, 4, 2)
        metres.replace(region: region, mipmapLevel: 0, withBytes: &distances, bytesPerRow: 16)
        confidence.replace(region: region, mipmapLevel: 0, withBytes: &qualities, bytesPerRow: 4)
        for (minimum, flip) in [(1, false), (2, false), (1, true)] {
            let command = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = result
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 0.123 // Every pixel must be overwritten.
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setFragmentTexture(metres, index: 0)
            encoder.setFragmentTexture(confidence, index: 1)
            var uniforms: [Float] = [flip ? -1 : 1, 0, flip ? 1 : 0, 0,
                0, 1, 0, 0, -10/9.9, -1/9.9, -1, 0, Float(minimum), 0, 0, 0]
            encoder.setFragmentBytes(&uniforms, length: uniforms.count * 4, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            let output = device.makeBuffer(length: 512, options: .storageModeShared)!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from: result, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: 4, height: 2, depth: 1),
                to: output, destinationOffset: 0, destinationBytesPerRow: 256,
                destinationBytesPerImage: 512)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed && command.error == nil)
            let values = output.contents().bindMemory(to: Float.self, capacity: 128)
            var expected: [Float] = [10/9.9 - 1/9.9, minimum == 1 ? 10/9.9 - 1/19.8 : 1,
                1, 1, 1, 1, 1, 1]
            if flip { expected = Array(expected[0..<4].reversed()) + Array(expected[4..<8].reversed()) }
            for y in 0..<2 {
                for x in 0..<4 {
                    let actual = values[y * 64 + x], wanted = expected[y * 4 + x]
                    precondition(abs(actual - wanted) < 0.000001,
                        "Depth mismatch at \(x),\(y): \(actual), wanted \(wanted)")
                }
            }
        }
        print("Metal depth shader: metric projection, confidence, invalid/range rejection and display flip passed (24 pixels).")
    }
}
