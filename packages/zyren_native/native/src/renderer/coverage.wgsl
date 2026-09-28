// The same threshold is used by overlapping surfaces. Adjacent half-open
// intervals keep exactly one fragment where both surfaces provide coverage.
fn fragment_coverage(screen: vec2<f32>, interval: vec2<f32>) {
    let pixel = vec2<u32>(screen);
    var hash = pixel.x * 1664525u + pixel.y * 1013904223u;
    hash = (hash ^ (hash >> 16u)) * 2246822519u;
    hash = hash ^ (hash >> 13u);
    let threshold = (f32(hash & 65535u) + .5) / 65536.;
    if threshold < interval.x || threshold >= interval.y { discard; }
}
