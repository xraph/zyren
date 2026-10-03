import CoreGraphics
import Foundation
import simd

enum XrCalibration {
    static func values(frameId: Int, timestamp: Double, revision: Int, epoch: Int,
                       projection: simd_float4x4, cameraTransform: simd_float4x4,
                       logical: CGSize, scale: CGFloat, orientation: Int,
                       near: Double, far: Double, depthEnabled: Bool,
                       displayTransform transform: CGAffineTransform) -> [String: Any] {
        func matrix(_ value: simd_float4x4) -> [Double] {
            (0..<4).flatMap { c in (0..<4).map { Double(value[c][$0]) } }
        }
        // Native raycasts read these values before Flutter bridges them to NSNumber.
        return ["frameId": frameId, "timestamp": timestamp, "revision": revision,
            "epoch": epoch, "projection": matrix(projection), "cameraTransform": matrix(cameraTransform),
            "logicalWidth": Double(logical.width), "logicalHeight": Double(logical.height), "devicePixelRatio": Double(scale),
            "pixelWidth": Int((logical.width * scale).rounded()), "pixelHeight": Int((logical.height * scale).rounded()),
            "orientation": orientation, "near": near, "far": far, "depthEnabled": depthEnabled,
            "depthTimestamp": depthEnabled ? timestamp : NSNull(),
            "displayTransform": [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].map(Double.init)]
    }
}
