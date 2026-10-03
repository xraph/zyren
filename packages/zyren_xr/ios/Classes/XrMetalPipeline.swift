import ARKit
import Metal
import QuartzCore

final class XrMetalPipeline {
    let runtime: XrMetalRuntime
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var cache: CVMetalTextureCache?
    var virtualColor: MTLTexture?
    init(token: UInt64) throws {
        runtime = try XrMetalRuntime(token: token)
        guard let queue = runtime.device.makeCommandQueue() else { throw XrMetalFailure("metalUnavailable", "Cannot create a Metal command queue.") }
        self.queue = queue
        let library = try runtime.device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cameraVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cameraFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try runtime.device.makeRenderPipelineState(descriptor: descriptor)
        guard CVMetalTextureCacheCreate(nil, nil, runtime.device, nil, &cache) == kCVReturnSuccess else {
            throw XrMetalFailure("cameraImport", "Cannot create the camera texture cache.")
        }
    }
    func draw(frame: ARFrame, transform: CGAffineTransform, drawable: CAMetalDrawable, packet: Data) throws {
        let image = frame.capturedImage
        let format = CVPixelBufferGetPixelFormatType(image)
        guard CVPixelBufferGetPlaneCount(image) == 2,
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw XrMetalFailure("cameraFormat", "The camera image must contain 8-bit Y and CbCr planes.")
        }
        func plane(_ index: Int, _ format: MTLPixelFormat) throws -> CVMetalTexture {
            var result: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache!, image, nil, format,
                CVPixelBufferGetWidthOfPlane(image, index), CVPixelBufferGetHeightOfPlane(image, index), index, &result) == kCVReturnSuccess,
                let value = result else { throw XrMetalFailure("cameraImport", "Cannot import a camera plane.") }
            return value
        }
        // The wrappers and ARFrame remain retained until both GPU operations end.
        let y = try plane(0, .r8Unorm), cbcr = try plane(1, .rg8Unorm)
        let width = drawable.texture.width, height = drawable.texture.height
        if virtualColor?.width != width || virtualColor?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            virtualColor = runtime.device.makeTexture(descriptor: descriptor)
        }
        guard let virtualColor = virtualColor else { throw XrMetalFailure("metalUnavailable", "Cannot allocate the virtual color target.") }
        try packet.withUnsafeBytes { bytes in
            try runtime.check(runtime.render(runtime.renderer, bytes.bindMemory(to: UInt8.self).baseAddress, packet.count,
                Unmanaged.passUnretained(virtualColor as AnyObject).toOpaque(),
                Unmanaged.passUnretained(virtualColor as AnyObject).toOpaque()))
        }
        guard let command = queue.makeCommandBuffer() else { throw XrMetalFailure("metalUnavailable", "Cannot allocate a camera command buffer.") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw XrMetalFailure("metalUnavailable", "Cannot encode camera composition.") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(cbcr), index: 1)
        encoder.setFragmentTexture(virtualColor, index: 2)
        // displayTransform maps camera coordinates to view coordinates.
        let t = transform.inverted()
        let video = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attachment = CVBufferGetAttachment(image, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() as? String
        let kr: Float, kb: Float
        if attachment == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { kr = 0.2126; kb = 0.0722 }
        else if attachment == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { kr = 0.2627; kb = 0.0593 }
        else if attachment == nil || attachment == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { kr = 0.299; kb = 0.114 }
        else { throw XrMetalFailure("cameraColor", "Unsupported camera YCbCr matrix.") }
        var uniforms: [Float] = [Float(t.a), Float(t.c), Float(t.tx), 0, Float(t.b), Float(t.d), Float(t.ty), 0,
            video ? 16.0/255 : 0, video ? 255.0/219 : 1, video ? 255.0/224 : 1, 0,
            kr, kb, 0, 0]
        encoder.setFragmentBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime((frame, y, cbcr)) {}
        if command.status != .completed { throw XrMetalFailure("metalCommand", command.error?.localizedDescription ?? "Camera composition failed.") }
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex cameraVertex(uint id [[vertex_id]]) {
      float2 uv = float2((id << 1) & 2, id & 2);
      return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
    }
    float3 linearize(float3 c) { return select(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), c > 0.04045); }
    float3 encodeSrgb(float3 c) { return select(c * 12.92, 1.055 * pow(max(c, 0.0), float3(1.0/2.4)) - 0.055, c > 0.0031308); }
    fragment float4 cameraFragment(Vertex in [[stage_in]], texture2d<float> y [[texture(0)]],
        texture2d<float> cbcr [[texture(1)]], texture2d<float> scene [[texture(2)]], constant float4 *u [[buffer(0)]]) {
      constexpr sampler s(filter::linear, address::clamp_to_edge);
      float3 p = float3(in.uv, 1);
      float2 uv = float2(dot(u[0].xyz,p), dot(u[1].xyz,p));
      float l = (y.sample(s, uv).r - u[2].x) * u[2].y;
      float2 c = (cbcr.sample(s, uv).rg - 128.0/255.0) * u[2].z;
      float kr = u[3].x, kb = u[3].y, kg = 1 - kr - kb;
      float3 rgb = float3(l + 2*(1-kr)*c.y, l - 2*kb*(1-kb)/kg*c.x - 2*kr*(1-kr)/kg*c.y, l + 2*(1-kb)*c.x);
      float4 virtualColor = scene.sample(s, in.uv);
      // Native surface output premultiplies in encoded sRGB for Core Animation.
      // Texture sampling decoded those stored bytes, so recover straight color
      // before blending in linear light against the camera image.
      float3 straight = virtualColor.a > 0 ? linearize(clamp(encodeSrgb(virtualColor.rgb) / virtualColor.a, 0.0, 1.0)) : float3(0);
      return float4(linearize(clamp(rgb, 0.0, 1.0)) * (1 - virtualColor.a) + straight * virtualColor.a, 1);
    }
    """
}
