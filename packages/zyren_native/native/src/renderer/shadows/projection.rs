use super::*;
pub(super) fn projections(
    frame: &Frame,
    signature: &Signature,
    geometries: &HashMap<u32, GpuGeometry>,
    columns: u32,
    cell: u32,
) -> Result<(Vec<Map>, Vec3), String> {
    let inverse = Mat4::from_cols_array(&frame.view_projection).inverse();
    let camera = (inverse.project_point3(Vec3::new(0., 0., 0.5))
        - inverse.project_point3(Vec3::ZERO))
    .normalize();
    let mut maps = Vec::new();
    for s in &signature.settings {
        let light = &signature.lights[s[0] as usize];
        let direction = Vec3::new(light[8], light[9], light[10]).normalize();
        let near = frame.settings.shadow_camera[0].max(0.001);
        let far = frame.settings.shadow_camera[1].min(s[4]);
        let light_view = glam::camera::rh::view::look_to_mat4(Vec3::ZERO, direction, up(direction));
        for cascade in 0..s[2] as usize {
            let split = |i: usize| {
                let t = i as f32 / s[2];
                (near + (far - near) * t) * (1. - s[7]) + near * (far / near).powf(t) * s[7]
            };
            let end = if light[3] == 0. {
                split(cascade + 1)
            } else {
                0.
            };
            let matrix = if light[3] == 2. {
                let position = Vec3::new(light[0], light[1], light[2]);
                spot_projection(light[13], s[3], s[4])
                    * glam::camera::rh::view::look_to_mat4(position, direction, up(direction))
            } else {
                let mut min = Vec3::splat(f32::INFINITY);
                let mut max = Vec3::splat(f32::NEG_INFINITY);
                for x in [-1., 1.] {
                    for y in [-1., 1.] {
                        let a = inverse.project_point3(Vec3::new(x, y, 0.));
                        let b = inverse.project_point3(Vec3::new(x, y, 0.5));
                        let ray = b - a;
                        for depth in [split(cascade), end] {
                            let point = a + ray * ((depth - camera.dot(a)) / camera.dot(ray));
                            let p = light_view.transform_point3(point);
                            min = min.min(p);
                            max = max.max(p);
                        }
                    }
                }
                for mesh in &signature.casters {
                    let model = light_view * Mat4::from_cols_array(&mesh.model);
                    let bounds = geometries[&mesh.geometry].bounds;
                    for x in [bounds[0].x, bounds[1].x] {
                        for y in [bounds[0].y, bounds[1].y] {
                            for z in [bounds[0].z, bounds[1].z] {
                                let depth = model.transform_point3(Vec3::new(x, y, z)).z;
                                min.z = min.z.min(depth);
                                max.z = max.z.max(depth);
                            }
                        }
                    }
                }
                let extent = (max - min).max(Vec3::splat(0.001));
                let texel = extent / s[1];
                let center = (min + max) * 0.5;
                let origin = light_view
                    .as_dmat4()
                    .transform_vector3(glam::DVec3::from_array(signature.origin));
                let snap = |center: f32, step: f32, origin: f64| {
                    (((center as f64 + origin) / step as f64).floor() * step as f64 - origin) as f32
                };
                let x = snap(center.x, texel.x, origin.x);
                let y = snap(center.y, texel.y, origin.y);
                glam::camera::rh::proj::directx::orthographic(
                    x - extent.x * 0.5 - texel.x,
                    x + extent.x * 0.5 + texel.x,
                    y - extent.y * 0.5 - texel.y,
                    y + extent.y * 0.5 + texel.y,
                    -max.z - 1.,
                    -min.z + 1.,
                ) * light_view
            };
            if !matrix.is_finite() {
                return Err("Nonfinite shadow projection".into());
            }
            let slot = maps.len() as u32;
            maps.push(Map {
                matrix,
                rect: [
                    slot % columns * cell,
                    slot / columns * cell,
                    s[1] as u32,
                    s[1] as u32,
                ],
                light: s[0] as u32,
                bias: s[5],
                normal_bias: s[6],
                end,
            });
        }
    }
    Ok((maps, camera))
}

fn spot_projection(cos_angle: f32, near: f32, far: f32) -> Mat4 {
    // Recover cot(angle) directly. acos followed by tan loses the sign near pi/2.
    let cotangent = cos_angle / (1. - cos_angle * cos_angle).sqrt();
    let depth = far / (near - far);
    Mat4::from_cols_array(&[
        cotangent,
        0.,
        0.,
        0.,
        0.,
        cotangent,
        0.,
        0.,
        0.,
        0.,
        depth,
        -1.,
        0.,
        0.,
        near * depth,
        0.,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wide_spot_projection_preserves_positive_scale_and_depth() {
        for cosine in [0.8, 0.01, 1e-12] {
            let matrix = spot_projection(cosine, 0.1, 10.);
            assert!(matrix.is_finite());
            assert!(matrix.x_axis.x > 0.);
            assert!((matrix.project_point3(Vec3::new(0., 0., -0.1)).z).abs() < 1e-6);
            assert!((matrix.project_point3(Vec3::new(0., 0., -10.)).z - 1.).abs() < 1e-6);
        }
    }
}
