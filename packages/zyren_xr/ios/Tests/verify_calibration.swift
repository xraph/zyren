// Run from the package root on macOS:
// swiftc ios/Classes/XrCalibration.swift ios/Tests/verify_calibration.swift -o /tmp/zyren-xr-calibration-test
// /tmp/zyren-xr-calibration-test
import CoreGraphics
import Foundation
import simd

@main
struct CalibrationTests {
    static func expect(_ condition: Bool, _ label: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL \(label)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let projection = simd_float4x4(diagonal: SIMD4<Float>(2, 3, 4, 1))
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4<Float>(1.25, -2.5, 3.75, 1)
        let transform = CGAffineTransform(a: 0, b: 0.75, c: -0.5, d: 0, tx: 0.875, ty: 0.125)
        for depthEnabled in [false, true] {
            let logical = depthEnabled ? CGSize(width: 844.5, height: 390.25) : CGSize(width: 390.25, height: 844.5)
            let calibration = XrCalibration.values(frameId: 7, timestamp: 12.75, revision: 3, epoch: 5,
                projection: projection, cameraTransform: pose, logical: logical, scale: 2.5,
                orientation: depthEnabled ? 3 : 1, near: 0.05, far: 100,
                depthEnabled: depthEnabled, displayTransform: transform)

            // Raycasts consume this dictionary before Flutter bridges its numbers.
            expect(calibration["logicalWidth"] as? Double == Double(logical.width), "native raycast width")
            expect(calibration["logicalHeight"] as? Double == Double(logical.height), "native raycast height")
            expect(calibration["devicePixelRatio"] as? Double == 2.5, "native pixel ratio")
            expect(calibration["displayTransform"] as? [Double] == [0, 0.75, -0.5, 0, 0.875, 0.125], "display transform")
            expect(calibration["projection"] as? [Double] == [2,0,0,0, 0,3,0,0, 0,0,4,0, 0,0,0,1], "projection columns")
            expect(calibration["cameraTransform"] as? [Double] == [1,0,0,0, 0,1,0,0, 0,0,1,0, 1.25,-2.5,3.75,1], "camera pose columns")
            expect(calibration["pixelWidth"] as? Int == (depthEnabled ? 2111 : 976), "rounded pixel width")
            expect(calibration["pixelHeight"] as? Int == (depthEnabled ? 976 : 2111), "rounded pixel height")
            expect(calibration["frameId"] as? Int == 7, "frame identity")
            expect(calibration["revision"] as? Int == 3 && calibration["epoch"] as? Int == 5, "revision and epoch")
            expect(calibration["orientation"] as? Int == (depthEnabled ? 3 : 1), "orientation")
            expect(calibration["timestamp"] as? Double == 12.75, "timestamp")
            expect(calibration["near"] as? Double == 0.05 && calibration["far"] as? Double == 100, "clipping range")
            expect(calibration["depthEnabled"] as? Bool == depthEnabled, "depth state")
            if depthEnabled {
                expect(calibration["depthTimestamp"] as? Double == 12.75, "depth timestamp")
            } else {
                expect(calibration["depthTimestamp"] is NSNull, "absent depth timestamp")
            }
        }
        print("PASS native calibration numbers, matrix layout, pixel rounding and depth state")
    }
}
