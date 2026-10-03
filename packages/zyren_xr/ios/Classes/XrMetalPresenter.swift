import ARKit
import Flutter
import QuartzCore
import UIKit

final class XrMetalView: UIView, FlutterPlatformView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    weak var presenter: XrMetalPresenter?
    func view() -> UIView { self }
    override func layoutSubviews() { super.layoutSubviews(); presenter?.layout(self) }
    override func didMoveToWindow() { super.didMoveToWindow(); presenter?.layout(self) }
}
final class XrMetalViewFactory: NSObject, FlutterPlatformViewFactory {
    weak var plugin: ZyrenXrPlugin?
    init(_ plugin: ZyrenXrPlugin) { self.plugin = plugin }
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        let view = XrMetalView(frame: frame)
        if let values = args as? [String: Any], let id = values["presenterId"] as? String {
            plugin?.attach(view, presenterId: id)
        }
        return view
    }
}

// Main queue owns leases, revisions and view state. The serial worker owns all
// native renderer calls. A busy renderer keeps its lease until GPU completion.
final class XrMetalPresenter {
    struct Lease {
        let id: Int
        let frame: ARFrame
        let epoch: Int
        let revision: Int
        let transform: CGAffineTransform
        let projection: simd_float4x4
        let depthEnabled: Bool
        let calibration: [String: Any]
    }
    let id = UUID().uuidString
    let worker = DispatchQueue(label: "zyren.xr.metal")
    var pipeline: XrMetalPipeline? // Worker only after initialization.
    weak var view: XrMetalView?
    var lease: Lease?
    var busy = false
    var closed = false
    var epoch = 0
    var nextFrame = 0
    var presented = 0
    var presentedCalibration: [String: Any]?
    var logical = CGSize.zero
    var scale: CGFloat = 1
    var orientation: UIInterfaceOrientation = .unknown
    var device: MTLDevice?

    static func create(token: UInt64, completion: @escaping (Result<XrMetalPresenter, Error>) -> Void) {
        let presenter = XrMetalPresenter()
        presenter.worker.async {
            do {
                let pipeline = try XrMetalPipeline(token: token)
                presenter.pipeline = pipeline
                DispatchQueue.main.async { presenter.device = pipeline.runtime.device; completion(.success(presenter)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func attach(_ view: XrMetalView) {
        self.view?.presenter = nil
        self.view = view
        view.presenter = self
        let layer = view.layer as! CAMetalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        revoke()
        layout(view)
    }
    func layout(_ view: XrMetalView) {
        guard self.view === view else { return }
        let size = view.window == nil ? .zero : view.bounds.size
        let scale = view.window?.screen.scale ?? 1
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .unknown
        if size != logical || scale != self.scale || orientation != self.orientation {
            logical = size; self.scale = scale; self.orientation = orientation
            revoke()
            (view.layer as! CAMetalLayer).drawableSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        }
    }
    func revoke() { epoch += 1; presentedCalibration = nil; if !busy { lease = nil } }
    func close(_ completion: @escaping FlutterResult) {
        closed = true; revoke(); view?.presenter = nil; view = nil
        worker.async { self.pipeline = nil; DispatchQueue.main.async { completion(nil) } }
    }
    func acquire(frame: ARFrame, revision: Int, near: Double, far: Double, depthEnabled: Bool) throws -> [String: Any] {
        if let view = view { layout(view) }
        guard !closed, !busy, lease == nil else { throw XrMetalFailure("busy", "A camera frame is already retained or the presenter is closed.") }
        guard logical.width > 0, logical.height > 0, logical.width * scale <= 4096,
              logical.height * scale <= 4096, orientation != .unknown else {
            throw XrMetalFailure("frameDeferred", "The camera view is not attached at a supported size.")
        }
        guard near.isFinite, far.isFinite, near > 0, far > near else { throw XrMetalFailure("invalidArguments", "Invalid camera clipping range.") }
        let projection = frame.camera.projectionMatrix(for: orientation, viewportSize: logical, zNear: near, zFar: far)
        let pose = frame.camera.viewMatrix(for: orientation).inverse
        let transform = frame.displayTransform(for: orientation, viewportSize: logical)
        nextFrame += 1
        let calibration = XrCalibration.values(frameId: nextFrame, timestamp: frame.timestamp,
            revision: revision, epoch: epoch, projection: projection, cameraTransform: pose,
            logical: logical, scale: scale, orientation: orientation.rawValue, near: near, far: far,
            depthEnabled: depthEnabled, displayTransform: transform)
        lease = Lease(id: nextFrame, frame: frame, epoch: epoch, revision: revision, transform: transform,
            projection: projection, depthEnabled: depthEnabled, calibration: calibration)
        return calibration
    }
    func cancel(_ frameId: Int) { if !busy && lease?.id == frameId { lease = nil } }
    func present(frameId: Int, revision: Int, packet: Data, currentRevision: @escaping () -> Int?, completion: @escaping FlutterResult) {
        if let view = view { layout(view) }
        guard !closed, !busy, let lease = lease, lease.id == frameId, lease.epoch == epoch,
              lease.revision == revision, let layer = view?.layer as? CAMetalLayer else {
            cancel(frameId); completion(Self.error(XrMetalFailure("frameDeferred", "The camera lease or viewport changed."))); return
        }
        busy = true
        worker.async {
            var failure: Error?
            var drawable: CAMetalDrawable?
            var nativeReadback: UInt64 = 0
            do {
                guard let pipeline = self.pipeline, let target = layer.nextDrawable() else { throw XrMetalFailure("frameDeferred", "The Metal drawable is unavailable.") }
                guard target.texture.width == lease.calibration["pixelWidth"] as? Int,
                      target.texture.height == lease.calibration["pixelHeight"] as? Int else {
                    throw XrMetalFailure("frameDeferred", "The drawable dimensions changed after calibration.")
                }
                drawable = target
                try pipeline.draw(frame: lease.frame, transform: lease.transform, projection: lease.projection,
                    depthEnabled: lease.depthEnabled, drawable: target, packet: packet)
                nativeReadback = pipeline.runtime.readback(pipeline.runtime.renderer)
            } catch {
                failure = error
                if (error as? XrMetalFailure)?.retryableFrame != true { self.pipeline = nil }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.lease = nil
                if let failure = failure {
                    if (failure as? XrMetalFailure)?.retryableFrame != true { self.closed = true }
                    completion(Self.error(failure)); return
                }
                if let view = self.view { self.layout(view) }
                guard self.view?.window != nil, !self.closed, self.epoch == lease.epoch, currentRevision() == lease.revision else {
                    completion(lease.calibration.merging(["applied": true, "presented": false]) { _, new in new }); return
                }
                drawable?.present()
                self.presented += 1
                self.presentedCalibration = lease.calibration
                completion(lease.calibration.merging(["applied": true, "presented": true, "cameraReadbackBytes": 0,
                    "inFlightLimit": 1, "heldCameraFrames": 0, "drawableLimit": 2, "nativeReadbackBytes": nativeReadback, "presentedFrames": self.presented]) { _, new in new })
            }
        }
    }
    func command(kind: String, data: Data, capacity: Int, completion: @escaping FlutterResult) {
        guard !closed else { completion(Self.error(XrMetalFailure("disposed", "The camera presenter is closed."))); return }
        worker.async {
            do {
                guard let pipeline = self.pipeline else { throw XrMetalFailure("disposed", "The camera presenter is closed.") }
                var response = try pipeline.runtime.command(kind, data: data, capacity: capacity)
                if let bytes = response["bytes"] as? Data { response["bytes"] = FlutterStandardTypedData(bytes: bytes) }
                DispatchQueue.main.async { completion(response) }
            } catch { DispatchQueue.main.async { completion(Self.error(error)) } }
        }
    }
    static func error(_ error: Error) -> FlutterError {
        let issue = error as? XrMetalFailure
        return FlutterError(code: issue?.code ?? "metalFailure", message: issue?.message ?? error.localizedDescription, details: nil)
    }
}
