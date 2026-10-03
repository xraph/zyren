enum XrDepthShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct DepthVertex { float4 position [[position]]; float2 uv; };
    struct DepthOutput { float depth [[depth(any)]]; };
    vertex DepthVertex depthVertex(uint id [[vertex_id]]) {
      float2 uv = float2((id << 1) & 2, id & 2);
      return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
    }
    fragment DepthOutput sceneDepth(DepthVertex in [[stage_in]],
        texture2d<float> metres [[texture(0)]], texture2d<uint> confidence [[texture(1)]],
        constant float4 *u [[buffer(0)]]) {
      float3 p = float3(in.uv, 1);
      float2 uv = float2(dot(u[0].xyz, p), dot(u[1].xyz, p));
      if (any(uv < 0) || any(uv >= 1)) return {1};
      uint2 point = min(uint2(uv * float2(metres.get_width(), metres.get_height())),
        uint2(metres.get_width()-1, metres.get_height()-1));
      float z = metres.read(point).r;
      uint quality = confidence.read(point).r;
      if (!isfinite(z) || z <= 0 || quality < uint(u[3].x) || quality > 2) return {1};
      float clipZ = u[2].x * -z + u[2].y;
      float clipW = u[2].z * -z + u[2].w;
      if (!isfinite(clipW) || clipW <= 0) return {1};
      float projected = clipZ / clipW;
      return {isfinite(projected) && projected >= 0 && projected <= 1 ? projected : 1};
    }
    """
}
