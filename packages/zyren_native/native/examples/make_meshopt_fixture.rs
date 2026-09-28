use serde_json::json;

fn main() {
    let vertices: [f32; 9] = [-1., -1., 0., 1., -1., 0., 0., 1., 0.];
    let indices = [0u32, 1, 2];
    let mut encoded = vec![0; 1024];
    let length = unsafe {
        meshopt::ffi::meshopt_encodeVertexBuffer(
            encoded.as_mut_ptr(),
            encoded.len(),
            vertices.as_ptr().cast(),
            3,
            12,
        )
    };
    encoded.truncate(length);
    let mut encoded_indices = vec![0; 256];
    let index_length = unsafe {
        meshopt::ffi::meshopt_encodeIndexBuffer(
            encoded_indices.as_mut_ptr(),
            encoded_indices.len(),
            indices.as_ptr(),
            3,
        )
    };
    encoded_indices.truncate(index_length);
    let directory =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test_assets/compression");
    std::fs::create_dir_all(&directory).unwrap();
    std::fs::write(directory.join("triangle.meshopt"), &encoded).unwrap();
    encoded.extend_from_slice(&encoded_indices);
    let root = json!({
        "asset": {"version":"2.0"},
        "extensionsUsed": ["EXT_meshopt_compression", "KHR_materials_unlit"],
        "extensionsRequired": ["EXT_meshopt_compression"],
        "buffers": [{"byteLength": encoded.len()}, {"byteLength": 42,
            "extensions": {"EXT_meshopt_compression": {"fallback": true}}}],
        "bufferViews": [
            {"buffer":1, "byteOffset":0, "byteLength":36, "extensions": {
                "EXT_meshopt_compression":{"buffer":0,"byteOffset":0,"byteLength":length,
                    "byteStride":12,"count":3,"mode":"ATTRIBUTES"}}},
            {"buffer":1, "byteOffset":36, "byteLength":6, "extensions": {
                "EXT_meshopt_compression":{"buffer":0,"byteOffset":length,"byteLength":index_length,
                    "byteStride":2,"count":3,"mode":"TRIANGLES"}}}
        ],
        "accessors": [
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[-1,-1,0],"max":[1,1,0]},
            {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
        ],
        "materials":[{"extensions":{"KHR_materials_unlit":{}},"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1]}}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
        "nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}],"scene":0
    });
    let mut json = serde_json::to_vec(&root).unwrap();
    while json.len() % 4 != 0 {
        json.push(b' ');
    }
    while encoded.len() % 4 != 0 {
        encoded.push(0);
    }
    let mut glb = Vec::new();
    for value in [
        0x46546c67,
        2,
        (28 + json.len() + encoded.len()) as u32,
        json.len() as u32,
        0x4e4f534a,
    ] {
        glb.extend_from_slice(&value.to_le_bytes());
    }
    glb.extend_from_slice(&json);
    glb.extend_from_slice(&(encoded.len() as u32).to_le_bytes());
    glb.extend_from_slice(&0x004e4942u32.to_le_bytes());
    glb.extend_from_slice(&encoded);
    std::fs::write(directory.join("triangle.glb"), glb).unwrap();
}
