import ARKit
import AVFoundation
import Flutter
import UIKit

public final class ZyrenXrPlugin: NSObject, FlutterPlugin, ARSessionDelegate {
    // All access occurs on the main queue, including ARSession delegate callbacks.
    // A second Flutter engine must not start a competing camera session.
    private static weak var owner: ZyrenXrPlugin?
    private var presenter: XrMetalPresenter?
    private var creatingPresenter = false
    private var session: ARSession?
    private var sessionId: String?
    private var state = "ready"
    private var pendingStart: FlutterResult?
    private var startRevision = 0
    private var runTimestamp = 0.0
    private var revision = 0
    private var originEpoch = 0
    private var depthEnabled = false
    private var failure: [String: Any]?
    private var appAnchors: [UUID: ARAnchor] = [:]
    private var backgroundObserver: NSObjectProtocol?
    private let anchorLimit = 128
    private let planeLimit = 128

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ZyrenXrPlugin()
        let channel = FlutterMethodChannel(
            name: "dev.zyren.xr/session.v1", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        // Publishing opts into detachFromEngine, including hot restart teardown.
        registrar.publish(instance)
        registrar.register(XrMetalViewFactory(instance), withId: "dev.zyren.xr/metal.v1")
        instance.backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak instance] _ in instance?.pause() }
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        close()
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
            backgroundObserver = nil
        }
    }

    deinit {
        session?.pause()
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handle(call, result: result) }
            return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "capabilities": result(capabilities()); return
        case "create":
            guard ARWorldTrackingConfiguration.isSupported else {
                result(error("unsupportedHardware", "ARKit world tracking is unavailable.")); return
            }
            guard Self.owner == nil, session == nil else {
                result(error("busy", "Another Zyren XR session owns the camera.")); return
            }
            let created = ARSession()
            created.delegateQueue = .main
            created.delegate = self
            session = created
            sessionId = UUID().uuidString
            state = "ready"
            revision = 0
            originEpoch = 0
            depthEnabled = false
            failure = nil
            Self.owner = self
            result(["sessionId": sessionId!]); return
        case "dispose":
            // A repeated disposal after release is harmless.
            if session == nil { result(nil); return }
        case "start", "pause", "snapshot", "addAnchor", "removeAnchor", "raycast", "planeGeometry",
             "createPresenter", "closePresenter", "acquireFrame", "cancelFrame", "presentFrame", "gpuCommand": break
        default: result(FlutterMethodNotImplemented); return
        }
        guard let id = args["sessionId"] as? String, id == sessionId, session != nil else {
            result(error("invalidSession", "The XR session has been released or replaced.")); return
        }
        switch call.method {
        case "createPresenter", "closePresenter", "acquireFrame", "cancelFrame", "presentFrame", "gpuCommand":
            presentation(call.method, args, result: result)
        case "start": start(args, result: result)
        case "pause": pause(); result(nil)
        case "dispose": close(result)
        case "snapshot": result(snapshot())
        case "raycast": raycast(args, result: result)
        case "planeGeometry":
            guard checkRevision(args, result: result) else { return }
            guard let frame = usableFrame(), ProcessInfo.processInfo.systemUptime - frame.timestamp <= 0.5 else {
                result(error("trackingUnavailable", "Plane geometry requires a fresh frame.")); return
            }
            guard let id = args["planeId"] as? String,
                  let plane = frame.anchors.compactMap({ $0 as? ARPlaneAnchor })
                    .first(where: { $0.identifier.uuidString == id }) else {
                result(error("unknownPlane", "The plane is no longer available.")); return
            }
            do { result(try XrRaycasts.geometry(plane, revision: revision, timestamp: frame.timestamp)) }
            catch { result(XrMetalPresenter.error(error)) }
        case "addAnchor": addAnchor(args, result: result)
        case "removeAnchor":
            guard checkRevision(args, result: result) else { return }
            guard let text = args["anchorId"] as? String, let id = UUID(uuidString: text),
                  let anchor = appAnchors.removeValue(forKey: id) else {
                result(error("unknownAnchor", "The anchor does not belong to this session.")); return
            }
            session?.remove(anchor: anchor)
            presenter?.revoke()
            revision += 1
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    func attach(_ view: XrMetalView, presenterId: String) {
        if presenter?.id == presenterId { presenter?.attach(view) }
    }

    private func raycast(_ args: [String: Any], result: FlutterResult) {
        guard checkRevision(args, result: result) else { return }
        guard let frame = usableFrame(), case .normal = frame.camera.trackingState,
              ProcessInfo.processInfo.systemUptime - frame.timestamp <= 0.5 else {
            result(error("trackingUnavailable", "Raycasting requires fresh normal tracking.")); return
        }
        guard let presenter = presenter, args["presenterId"] as? String == presenter.id else {
            result(error("invalidPresenter", "The camera presenter has been released.")); return
        }
        if let view = presenter.view { presenter.layout(view) }
        guard let calibration = presenter.presentedCalibration,
              args["frameId"] as? Int == calibration["frameId"] as? Int,
              args["epoch"] as? Int == calibration["epoch"] as? Int,
              let timestamp = calibration["timestamp"] as? Double,
              frame.timestamp >= timestamp, frame.timestamp - timestamp <= 0.5,
              let x = args["x"] as? Double, let y = args["y"] as? Double else {
            result(error("staleFrame", "Render a fresh view before raycasting.")); return
        }
        do {
            var hits = try XrRaycasts.query(session: session!, calibration: calibration, x: x, y: y,
                sensorTimestamp: frame.timestamp, revision: revision, originEpoch: originEpoch)
            hits["presenterId"] = presenter.id
            result(hits)
        } catch { result(XrMetalPresenter.error(error)) }
    }

    private func presentation(_ method: String, _ args: [String: Any], result: @escaping FlutterResult) {
        if method == "createPresenter" {
            guard presenter == nil, !creatingPresenter, let token = args["runtime"] as? NSNumber else {
                result(error("busy", "A camera presenter exists or the runtime token is missing.")); return
            }
            creatingPresenter = true
            let owner = sessionId
            // Method channels carry signed Int64. Preserve every runtime token bit.
            XrMetalPresenter.create(token: token.uint64Value) { outcome in
                self.creatingPresenter = false
                switch outcome {
                case .failure(let issue): result(XrMetalPresenter.error(issue))
                case .success(let created):
                    guard self.sessionId == owner, self.session != nil else {
                        created.close { _ in result(self.error("disposed", "The session closed during presenter creation.")) }; return
                    }
                    self.presenter = created
                    result(["presenterId": created.id])
                }
            }
            return
        }
        guard let presenter = presenter, args["presenterId"] as? String == presenter.id else {
            result(error("invalidPresenter", "The camera presenter has been released or replaced.")); return
        }
        switch method {
        case "closePresenter": self.presenter = nil; presenter.close(result)
        case "acquireFrame":
            guard let frame = usableFrame(), ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.5 else {
                result(error("trackingUnavailable", "No fresh ARKit frame is available.")); return
            }
            do { result(try presenter.acquire(frame: frame, revision: revision,
                near: args["near"] as? Double ?? 0.01, far: args["far"] as? Double ?? 1000,
                depthEnabled: depthEnabled)) }
            catch { result(XrMetalPresenter.error(error)) }
        case "cancelFrame": presenter.cancel(args["frameId"] as? Int ?? -1); result(nil)
        case "presentFrame":
            guard let data = args["packet"] as? FlutterStandardTypedData,
                  let frameId = args["frameId"] as? Int, let expected = args["revision"] as? Int else {
                result(error("invalidArguments", "A scene packet and camera lease are required.")); return
            }
            presenter.present(frameId: frameId, revision: expected, packet: data.data,
                currentRevision: { [weak self] in self?.state == "running" ? self?.revision : nil }, completion: result)
        case "gpuCommand":
            guard let data = args["bytes"] as? FlutterStandardTypedData, let kind = args["kind"] as? String,
                  let capacity = args["capacity"] as? Int else {
                result(error("invalidArguments", "A GPU command is required.")); return
            }
            presenter.command(kind: kind, data: data.data, capacity: capacity, completion: result)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func capabilities() -> [String: Any] {
        let tracking = ARWorldTrackingConfiguration.isSupported
        return [
            "platform": "arkit", "worldTracking": tracking,
            "planeDetection": tracking, "anchors": tracking,
            "lightEstimation": tracking,
            "sceneDepthHardware": tracking && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            "cameraPresentation": tracking,
            "depthOcclusion": tracking && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            "cameraPermission": permissionName()
        ]
    }

    private func permissionName() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return "notDetermined"
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "restricted"
        }
    }

    private func start(_ args: [String: Any], result: @escaping FlutterResult) {
        guard pendingStart == nil else {
            result(error("busy", "Camera authorization is already pending.")); return
        }
        guard state != "failed" else {
            result(error("sessionFailed", "Dispose and recreate the failed ARKit session.", failure)); return
        }
        guard let horizontal = args["horizontalPlanes"] as? Bool,
              let vertical = args["verticalPlanes"] as? Bool,
              let light = args["lightEstimation"] as? Bool,
              let camera = args["requireCameraPresentation"] as? Bool,
              let depth = args["requireDepthOcclusion"] as? Bool,
              let reset = args["resetTracking"] as? Bool else {
            result(error("invalidArguments", "The session configuration is incomplete.")); return
        }
        guard !depth || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            result(error("unsupportedFeature", "This device does not provide scene depth.")); return
        }
        guard state != "running" || reset else {
            result(error("invalidState", "Pause before reconfiguring, or explicitly reset tracking.")); return
        }
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result(error("missingCameraUsageDescription", "Add NSCameraUsageDescription to the host Info.plist.")); return
        }
        guard UIApplication.shared.applicationState == .active else {
            result(error("appInactive", "Start XR while the application is active.")); return
        }
        _ = camera
        presenter?.revoke()
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isLightEstimationEnabled = light
        if depth { configuration.frameSemantics.insert(.sceneDepth) }
        if horizontal { configuration.planeDetection.insert(.horizontal) }
        if vertical { configuration.planeDetection.insert(.vertical) }
        pendingStart = result
        state = "starting"
        failure = nil
        startRevision += 1
        let revision = startRevision
        let proceed: (Bool) -> Void = { [weak self] allowed in
            guard let self = self, self.startRevision == revision,
                  let completion = self.pendingStart, let session = self.session else { return }
            self.pendingStart = nil
            guard allowed else {
                self.state = "paused"
                let code = self.permissionName() == "restricted" ? "permissionRestricted" : "permissionDenied"
                self.failure = ["code": code, "message": "Camera access is unavailable."]
                completion(self.error(code, "Camera access is unavailable.")); return
            }
            guard UIApplication.shared.applicationState == .active else {
                self.state = "paused"
                completion(self.error("appInactive", "The application left the foreground.")); return
            }
            var options: ARSession.RunOptions = []
            if reset {
                options = [.resetTracking, .removeExistingAnchors]
                self.appAnchors.removeAll()
                self.originEpoch += 1
            }
            // Prevent currentFrame from a previous run appearing as fresh tracking.
            self.runTimestamp = ProcessInfo.processInfo.systemUptime
            self.state = "running"
            self.depthEnabled = depth
            self.revision += 1
            session.run(configuration, options: options)
            completion(nil)
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: proceed(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                DispatchQueue.main.async { proceed(allowed) }
            }
        default: proceed(false)
        }
    }

    private func cancelStart() {
        startRevision += 1
        let completion = pendingStart
        pendingStart = nil
        completion?(error("cancelled", "The session start was cancelled."))
    }

    private func pause() {
        guard session != nil else { return }
        cancelStart()
        session?.pause()
        if state != "failed" { state = "paused" }
        presenter?.revoke()
        revision += 1
    }

    private func close(_ completion: FlutterResult? = nil) {
        let retiring = presenter
        presenter = nil
        cancelStart()
        session?.delegate = nil
        session?.pause()
        session = nil
        sessionId = nil
        appAnchors.removeAll()
        failure = nil
        if Self.owner === self { Self.owner = nil }
        if let retiring = retiring { retiring.close { value in completion?(value) } }
        else { completion?(nil) }
    }

    private func usableFrame() -> ARFrame? {
        guard state == "running", let frame = session?.currentFrame,
              frame.timestamp >= runTimestamp else { return nil }
        return frame
    }

    private func snapshot() -> [String: Any] {
        var response: [String: Any] = [
            "sessionId": sessionId!, "originEpoch": originEpoch,
            "state": state, "revision": revision, "nativeTimestamp": ProcessInfo.processInfo.systemUptime
        ]
        if let failure = failure { response["failure"] = failure }
        guard let frame = usableFrame() else { return response }
        let camera = frame.camera
        let tracking = trackingState(camera.trackingState)
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
        var value: [String: Any] = [
            "timestamp": frame.timestamp, "cameraTransform": matrix(camera.transform),
            "tracking": tracking.0, "intrinsics": matrix(camera.intrinsics),
            "imageWidth": Int(camera.imageResolution.width),
            "imageHeight": Int(camera.imageResolution.height),
            "anchors": frame.anchors.filter { appAnchors[$0.identifier] != nil }
                .sorted { $0.identifier.uuidString < $1.identifier.uuidString }.map { anchor in
                    ["id": anchor.identifier.uuidString, "transform": matrix(anchor.transform)]
                },
            "planes": planes.prefix(planeLimit).map { plane in
                ["id": plane.identifier.uuidString, "transform": matrix(plane.transform),
                 "alignment": plane.alignment == .horizontal ? "horizontal" : "vertical",
                 "center": vector(plane.center), "extent": vector(plane.extent)] as [String: Any]
            },
            "omittedPlanes": max(0, planes.count - planeLimit)
        ]
        if let reason = tracking.1 { value["trackingReason"] = reason }
        if let light = frame.lightEstimate {
            value["light"] = ["ambientIntensity": light.ambientIntensity,
                              "colorTemperature": light.ambientColorTemperature]
        }
        response["frame"] = value
        return response
    }

    private func addAnchor(_ args: [String: Any], result: @escaping FlutterResult) {
        if args["expectedPresenterId"] != nil || args["expectedPresentationEpoch"] != nil {
            if let view = presenter?.view { presenter?.layout(view) }
            guard let presenter = presenter, presenter.view?.window != nil,
                  args["expectedPresenterId"] as? String == presenter.id,
                  args["expectedPresentationEpoch"] as? Int == presenter.epoch else {
                result(error("staleFrame", "The camera presentation changed before placement.")); return
            }
        }
        guard checkRevision(args, result: result) else { return }
        guard let frame = usableFrame(), case .normal = frame.camera.trackingState,
              ProcessInfo.processInfo.systemUptime - frame.timestamp < 0.5 else {
            result(error("trackingUnavailable", "Anchor placement needs a fresh frame with normal tracking.")); return
        }
        if let expected = args["expectedFrameTimestamp"] as? Double {
            guard expected.isFinite, expected <= frame.timestamp,
                  frame.timestamp - expected <= 0.5 else {
                result(error("staleFrame", "The placement frame is stale or from a different clock.")); return
            }
        }
        guard appAnchors.count < anchorLimit else {
            result(error("anchorLimit", "Remove an anchor before adding another (limit 128).")); return
        }
        guard let values = args["transform"] as? [Double], let transform = pose(values) else {
            result(error("invalidArguments", "Anchor transform must be a finite right-handed rigid matrix.")); return
        }
        let anchor = ARAnchor(transform: transform)
        appAnchors[anchor.identifier] = anchor
        session?.add(anchor: anchor)
        presenter?.revoke()
        revision += 1
        result(["anchorId": anchor.identifier.uuidString])
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === self.session else { return }
        cancelStart()
        session.pause()
        state = "failed"
        presenter?.revoke()
        revision += 1
        let native = error as NSError
        failure = ["code": "nativeFailure", "message": native.localizedDescription,
                   "details": ["domain": native.domain, "code": native.code]]
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        guard session === self.session, state == "running" else { return }
        state = "interrupted"
        presenter?.revoke()
        revision += 1
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        guard session === self.session, state == "interrupted" else { return }
        // Require the app to choose whether to resume its origin or reset it.
        session.pause()
        state = "paused"
        presenter?.revoke()
        revision += 1
    }

    private func checkRevision(_ args: [String: Any], result: FlutterResult) -> Bool {
        if let value = args["expectedRevision"] {
            guard let expected = value as? Int, expected == revision else {
                result(error("staleRevision", "The native session changed before this action.")); return false
            }
        }
        return true
    }

    private func trackingState(_ state: ARCamera.TrackingState) -> (String, String?) {
        switch state {
        case .normal: return ("normal", nil)
        case .notAvailable: return ("unavailable", nil)
        case .limited(let reason):
            switch reason {
            case .initializing: return ("limited", "initializing")
            case .excessiveMotion: return ("limited", "excessiveMotion")
            case .insufficientFeatures: return ("limited", "insufficientFeatures")
            case .relocalizing: return ("limited", "relocalizing")
            @unknown default: return ("limited", "unknown")
            }
        }
    }

    private func pose(_ values: [Double]) -> simd_float4x4? {
        guard values.count == 16, values.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { return nil }
        let v = values.map { Float($0) }
        let m = simd_float4x4(
            SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
            SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
        let axes = [SIMD3(v[0], v[1], v[2]), SIMD3(v[4], v[5], v[6]), SIMD3(v[8], v[9], v[10])]
        guard abs(v[3]) <= 0.002, abs(v[7]) <= 0.002, abs(v[11]) <= 0.002,
              abs(v[15] - 1) <= 0.002, abs(simd_determinant(m) - 1) <= 0.004 else { return nil }
        for a in 0..<3 {
            for b in 0..<3 {
                if abs(simd_dot(axes[a], axes[b]) - (a == b ? 1 : 0)) > 0.002 { return nil }
            }
        }
        return m
    }

    private func matrix(_ value: simd_float4x4) -> [Double] {
        (0..<4).flatMap { column in (0..<4).map { Double(value[column][$0]) } }
    }
    private func matrix(_ value: simd_float3x3) -> [Double] {
        (0..<3).flatMap { column in (0..<3).map { Double(value[column][$0]) } }
    }
    private func vector(_ value: SIMD3<Float>) -> [Double] {
        [Double(value.x), Double(value.y), Double(value.z)]
    }
    private func error(_ code: String, _ message: String, _ details: Any? = nil) -> FlutterError {
        FlutterError(code: code, message: message, details: details)
    }
}
