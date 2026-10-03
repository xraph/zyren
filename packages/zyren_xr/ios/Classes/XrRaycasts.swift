import ARKit

enum XrRaycasts {
    static func query(session: ARSession, calibration: [String: Any], x: Double, y: Double,
                      sensorTimestamp: Double, revision: Int, originEpoch: Int) throws -> [String: Any] {
        guard let width = calibration["logicalWidth"] as? Double,
              let height = calibration["logicalHeight"] as? Double,
              x.isFinite, y.isFinite, x >= 0, y >= 0, x < width, y < height,
              let projection = matrix(calibration["projection"]),
              let pose = matrix(calibration["cameraTransform"]) else {
            throw XrMetalFailure("invalidArguments", "The point must lie inside the presented viewport.")
        }
        let clip = SIMD4<Float>(Float(x / width * 2 - 1), Float(1 - y / height * 2), 0, 1)
        let camera = projection.inverse * clip
        let direction = pose * SIMD4<Float>(camera.x / camera.w, camera.y / camera.w, camera.z / camera.w, 0)
        let origin = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let ray = simd_normalize(SIMD3<Float>(direction.x, direction.y, direction.z))
        guard ray.x.isFinite, ray.y.isFinite, ray.z.isFinite else {
            throw XrMetalFailure("invalidCalibration", "The calibrated ray is invalid.")
        }
        let query = ARRaycastQuery(origin: origin, direction: ray,
            allowing: .existingPlaneGeometry, alignment: .any)
        let hits = session.raycast(query)
        return ["frameId": calibration["frameId"]!, "epoch": calibration["epoch"]!,
            "frameTimestamp": calibration["timestamp"]!, "sensorTimestamp": sensorTimestamp,
            "sessionRevision": revision, "originEpoch": originEpoch,
            "omittedHits": max(0, hits.count - 16), "coverage": "native-plane-geometry-estimate",
            "hits": hits.prefix(16).map { hit -> [String: Any] in
                let t = hit.worldTransform
                let point = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                return ["planeId": hit.anchor?.identifier.uuidString as Any? ?? NSNull(),
                    "transform": values(t), "distance": Double(simd_distance(point, origin))]
            }]
    }

    static func geometry(_ plane: ARPlaneAnchor, revision: Int, timestamp: Double) throws -> [String: Any] {
        let geometry = plane.geometry
        guard geometry.vertices.count <= 4096, geometry.triangleCount <= 4096,
              geometry.boundaryVertices.count <= 1024 else {
            throw XrMetalFailure("geometryTooLarge", "This plane exceeds the bounded geometry response.")
        }
        return ["planeId": plane.identifier.uuidString, "sessionRevision": revision,
            "frameTimestamp": timestamp, "transform": values(plane.transform),
            "vertices": (0..<geometry.vertices.count).flatMap { i in
                let p = geometry.vertices[i]; return [Double(p.x), Double(p.y), Double(p.z)]
            }, "indices": (0..<(geometry.triangleCount * 3)).map { Int(geometry.triangleIndices[$0]) },
            "boundary": (0..<geometry.boundaryVertices.count).flatMap { i in
                let p = geometry.boundaryVertices[i]; return [Double(p.x), Double(p.y), Double(p.z)]
            }]
    }
    private static func matrix(_ value: Any?) -> simd_float4x4? {
        guard let v = value as? [Double], v.count == 16 else { return nil }
        let f = v.map(Float.init)
        return simd_float4x4(SIMD4(f[0], f[1], f[2], f[3]),
            SIMD4(f[4], f[5], f[6], f[7]), SIMD4(f[8], f[9], f[10], f[11]),
            SIMD4(f[12], f[13], f[14], f[15]))
    }
    private static func values(_ m: simd_float4x4) -> [Double] {
        (0..<4).flatMap { c in (0..<4).map { Double(m[c][$0]) } }
    }
}
