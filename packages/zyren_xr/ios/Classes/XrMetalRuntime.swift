import Foundation
import Metal
import MachO

// Every call belongs to the presenter's serial queue. The loaded Dart native
// asset is found by token; this adapter never loads another runtime image.
final class XrMetalRuntime {
    typealias Readback = @convention(c) (UInt64) -> UInt64
    typealias Create = @convention(c) () -> UInt64
    typealias Destroy = @convention(c) (UInt64) -> UInt32
    typealias Device = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    typealias Render = @convention(c) (UInt64, UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UInt32
    typealias RenderTargets = @convention(c) (UInt64, UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UInt32
    typealias Command = @convention(c) (UInt64, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>?) -> UInt32
    typealias LastError = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Int
    let library: UnsafeMutableRawPointer
    let renderer: UInt64
    let device: MTLDevice
    let readback: Readback
    let render: Render
    let renderTargets: RenderTargets
    let destroy: Destroy
    let lastError: LastError
    let commands: [String: Command]

    init(token: UInt64) throws {
        var loaded: UnsafeMutableRawPointer?
        for index in 0..<_dyld_image_count() {
            guard let path = _dyld_get_image_name(index), String(cString: path).contains("zyren_runtime"),
                  let handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD) else { continue }
            if let symbol = dlsym(handle, "fg2_runtime_token"),
               unsafeBitCast(symbol, to: Create.self)() == token { loaded = handle; break }
            dlclose(handle)
        }
        guard let handle = loaded else { throw XrMetalFailure("runtimeMismatch", "Load the Zyren native asset before creating the camera view.") }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw XrMetalFailure("missingSymbol", name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            let create = try symbol("fg_create", Create.self)
            destroy = try symbol("fg_destroy", Destroy.self)
            readback = try symbol("fg_metal_readback_bytes", Readback.self)
            render = try symbol("fg_metal_render_texture", Render.self)
            renderTargets = try symbol("fg_metal_render_targets", RenderTargets.self)
            lastError = try symbol("fg_last_error", LastError.self)
            commands = try ["resource": symbol("fg2_resource_command", Command.self),
                            "shader": symbol("fg2_shader_command", Command.self),
                            "graph": symbol("fg2_graph_command", Command.self)]
            let copyDevice = try symbol("fg_metal_copy_device", Device.self)
            let created = create()
            guard created != 0 else { throw XrMetalFailure("rendererUnavailable", "Cannot create the native renderer.") }
            guard let pointer = copyDevice(created) else {
                _ = destroy(created)
                throw XrMetalFailure("metalUnavailable", "The native renderer has no Metal device.")
            }
            renderer = created
            device = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as! MTLDevice
            library = handle
        } catch { dlclose(handle); throw error }
    }
    deinit { _ = destroy(renderer); dlclose(library) }
    func check(_ status: UInt32) throws {
        guard status != 1 else { return }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = lastError(&bytes, bytes.count)
        throw XrMetalFailure("nativeRender", String(decoding: bytes.prefix(min(count, bytes.count)), as: UTF8.self))
    }
    func command(_ kind: String, data: Data, capacity: Int) throws -> [String: Any] {
        guard let call = commands[kind], capacity > 0, capacity <= 16 * 1024 * 1024 else {
            throw XrMetalFailure("invalidArguments", "Invalid GPU command or response capacity.")
        }
        var output = [UInt8](repeating: 0, count: capacity), written = 0
        let status = data.withUnsafeBytes { call(renderer, $0.bindMemory(to: UInt8.self).baseAddress, data.count, &output, capacity, &written) }
        if status != 0 {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = lastError(&bytes, bytes.count)
            return ["status": status, "message": String(decoding: bytes.prefix(min(count, bytes.count)), as: UTF8.self)]
        }
        guard written <= capacity else { throw XrMetalFailure("nativeRender", "GPU response exceeded its capacity.") }
        return ["status": 0, "bytes": Data(output.prefix(written))]
    }
}
struct XrMetalFailure: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var retryableFrame: Bool { ["frameDeferred", "staleDepth", "depthUnavailable"].contains(code) }
}
