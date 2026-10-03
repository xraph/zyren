// Run on macOS: swift ios/Tests/verify_compositor.swift ios/Classes/XrMetalPipeline.swift
// Synthetic textures only. Production camera presentation never reads pixels.
import Foundation
import Metal

let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let shader = source.components(separatedBy: "private static let shader = \"\"\"")[1].components(separatedBy: "\"\"\"")[0]
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
let library = try device.makeLibrary(source: shader, options: nil)
let desc = MTLRenderPipelineDescriptor()
desc.vertexFunction = library.makeFunction(name: "cameraVertex")
desc.fragmentFunction = library.makeFunction(name: "cameraFragment")
desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
let pipeline = try device.makeRenderPipelineState(descriptor: desc)
func texture(_ format: MTLPixelFormat, _ bytes: [UInt8], render: Bool = false) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 2, height: 2, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = render ? [.renderTarget] : [.shaderRead]
    let value = device.makeTexture(descriptor: descriptor)!
    if !render { value.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytes.count / 2) }
    return value
}
func draw(y: UInt8, video: Bool, virtual: [UInt8]) -> [UInt8] {
    let yTexture = texture(.r8Unorm, [y,y,y,y])
    let chroma = texture(.rg8Unorm, Array(repeating: [UInt8(128),128], count: 4).flatMap { $0 })
    let color = texture(.bgra8Unorm_srgb, Array(repeating: virtual, count: 4).flatMap { $0 })
    let output = texture(.bgra8Unorm_srgb, [], render: true)
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = output
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(yTexture, index: 0)
    encoder.setFragmentTexture(chroma, index: 1)
    encoder.setFragmentTexture(color, index: 2)
    var uniforms: [Float] = [1,0,0,0,0,1,0,0,video ? 16.0/255 : 0,video ? 255.0/219 : 1,video ? 255.0/224 : 1,0,0.299,0.114,0,0]
    encoder.setFragmentBytes(&uniforms, length: uniforms.count * 4, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed, "GPU composition failed")
    var bytes = [UInt8](repeating: 0, count: 16)
    output.getBytes(&bytes, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
    return Array(bytes.prefix(4))
}
func expect(_ actual: [UInt8], _ expected: [Int], _ label: String) {
    precondition(zip(actual, expected).allSatisfy { abs(Int($0) - $1) <= 2 }, "\(label): \(actual) expected \(expected)")
    print("PASS \(label): \(actual)")
}
expect(draw(y: 0, video: false, virtual: [0,0,0,0]), [0,0,0,255], "full-range black")
expect(draw(y: 255, video: false, virtual: [0,0,0,0]), [255,255,255,255], "full-range white")
expect(draw(y: 16, video: true, virtual: [0,0,0,0]), [0,0,0,255], "video-range black")
expect(draw(y: 235, video: true, virtual: [0,0,0,0]), [255,255,255,255], "video-range white")
expect(draw(y: 0, video: false, virtual: [0,0,128,128]), [0,0,188,255], "encoded-premultiplied half-red over black")
expect(draw(y: 255, video: false, virtual: [0,0,128,128]), [187,187,255,255], "encoded-premultiplied half-red over white")
expect(draw(y: 255, video: false, virtual: [255,0,0,255]), [255,0,0,255], "opaque virtual blue")
