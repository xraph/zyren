import ARKit
import Metal

// The ARFrame owns sceneDepth and its confidence map at the camera timestamp.
// Keep the CVMetalTexture wrappers alive until the consumer finishes rendering.
struct XrDepthLease {
    let frame: ARFrame
    let depth: CVMetalTexture
    let confidence: CVMetalTexture
    let target: MTLTexture
}

final class XrDepthPipeline {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var target: MTLTexture?

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: XrDepthShader.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "depthVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneDepth")
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let state = MTLDepthStencilDescriptor()
        state.depthCompareFunction = .always
        state.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: state) else {
            throw XrMetalFailure("depthUnavailable", "Cannot create the depth comparison state.")
        }
        self.depthState = depthState
    }

    func prepare(frame: ARFrame, transform: CGAffineTransform, projection: simd_float4x4,
                 width: Int, height: Int, cache: CVMetalTextureCache,
                 queue: MTLCommandQueue, minimumConfidence: Int = 1) throws -> XrDepthLease {
        let age = ProcessInfo.processInfo.systemUptime - frame.timestamp
        guard age >= 0, age <= 0.25 else {
            throw XrMetalFailure("staleDepth", "Scene depth is older than 250 milliseconds.")
        }
        guard let sceneDepth = frame.sceneDepth, let confidence = sceneDepth.confidenceMap else {
            throw XrMetalFailure("depthUnavailable", "This frame has no scene depth and confidence map.")
        }
        guard (0...2).contains(minimumConfidence),
              CVPixelBufferGetPixelFormatType(sceneDepth.depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(sceneDepth.depthMap) == CVPixelBufferGetWidth(confidence),
              CVPixelBufferGetHeight(sceneDepth.depthMap) == CVPixelBufferGetHeight(confidence) else {
            throw XrMetalFailure("depthFormat", "Depth and confidence must have matching supported layouts.")
        }
        func importTexture(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat) throws -> CVMetalTexture {
            var texture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture)
            guard status == kCVReturnSuccess, let texture = texture,
                  CVMetalTextureGetTexture(texture) != nil else {
                throw XrMetalFailure("depthImport", "Cannot import the scene depth texture.")
            }
            return texture
        }
        let depth = try importTexture(sceneDepth.depthMap, .r32Float)
        let quality = try importTexture(confidence, .r8Uint)
        if target?.width != width || target?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .private
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let target = target, let command = queue.makeCommandBuffer() else {
            throw XrMetalFailure("depthUnavailable", "Cannot allocate the depth render target.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = target
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw XrMetalFailure("depthUnavailable", "Cannot encode scene depth.")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(depth), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(quality), index: 1)
        let t = transform.inverted()
        var uniforms: [Float] = [Float(t.a), Float(t.c), Float(t.tx), 0,
            Float(t.b), Float(t.d), Float(t.ty), 0,
            projection.columns.2.z, projection.columns.3.z,
            projection.columns.2.w, projection.columns.3.w,
            Float(minimumConfidence), 0, 0, 0]
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        let lease = XrDepthLease(frame: frame, depth: depth, confidence: quality, target: target)
        withExtendedLifetime(lease) {}
        guard command.status == .completed, command.error == nil else {
            throw XrMetalFailure("metalCommand", command.error?.localizedDescription ?? "Depth conversion failed.")
        }
        return lease
    }
}
