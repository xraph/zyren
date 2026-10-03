use base64::{Engine, engine::general_purpose::STANDARD};
use basisu_c_sys::{
    BasisTextureFormat, common,
    extra::{types::Extent3d, *},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{self, Read};

const VERSION: &str = "zyren-pipeline-prepare/1;meshopt=0.6.2;basisu_c_sys=0.9.1";
#[derive(Deserialize)]
#[serde(tag = "operation", deny_unknown_fields)]
enum Request {
    #[serde(rename = "mesh")]
    Mesh {
        positions: Vec<f32>,
        indices: Vec<u32>,
        #[serde(default)]
        locked: Vec<usize>,
        #[serde(default)]
        attributes: Vec<f32>,
        #[serde(default)]
        weights: Vec<f32>,
        #[serde(default)]
        ratio: Option<f32>,
        #[serde(default)]
        max_error: f32,
    },
    #[serde(rename = "texture")]
    Texture {
        width: u32,
        height: u32,
        rgba: String,
        srgb: bool,
        mipmaps: bool,
        format: String,
        quality: i32,
        effort: i32,
    },
}
fn prepare(request: Request) -> Result<Value, String> {
    match request {
        Request::Mesh {
            positions,
            indices,
            locked,
            attributes,
            weights,
            ratio,
            max_error,
        } => {
            let count = positions.len() / 3;
            if !(3..=1_000_000).contains(&count)
                || positions.len() % 3 != 0
                || positions.iter().any(|v| !v.is_finite())
                || indices.is_empty()
                || indices.len() > 6_000_000
                || indices.len() % 3 != 0
                || indices.iter().any(|&i| i as usize >= count)
                || locked.iter().any(|&i| i >= count)
                || !max_error.is_finite()
                || max_error < 0.0
                || weights.len() > 32
                || weights.iter().any(|v| !v.is_finite() || *v < 0.0)
                || attributes.len() != count * weights.len()
                || attributes.iter().any(|v| !v.is_finite())
            {
                return Err("invalid mesh or preparation budget exceeded".into());
            }
            let bytes: Vec<u8> = positions.iter().flat_map(|v| v.to_le_bytes()).collect();
            let vertices =
                meshopt::VertexDataAdapter::new(&bytes, 12, 0).map_err(|_| "invalid positions")?;
            let mut error = 0.0;
            let mut simplified = indices.clone();
            if let Some(ratio) = ratio {
                if !ratio.is_finite() || ratio <= 0.0 || ratio > 1.0 {
                    return Err("invalid LOD ratio".into());
                }
                let target = (((indices.len() / 3) as f32 * ratio).floor() as usize).max(1) * 3;
                let mut locks = vec![false; count];
                for index in locked {
                    locks[index] = true;
                }
                simplified = meshopt::simplify_with_attributes_and_locks(
                    &indices,
                    &vertices,
                    &attributes,
                    &weights,
                    weights.len() * 4,
                    &locks,
                    target,
                    max_error,
                    meshopt::SimplifyOptions::LockBorder | meshopt::SimplifyOptions::ErrorAbsolute,
                    Some(&mut error),
                );
            }
            let optimized = meshopt::optimize_vertex_cache(&simplified, count);
            let before = meshopt::analyze_vertex_cache(&simplified, count, 16, 0, 0);
            let after = meshopt::analyze_vertex_cache(&optimized, count, 16, 0, 0);
            // Keep input order if this simulated cache metric does not improve.
            let result = if after.acmr <= before.acmr {
                optimized
            } else {
                simplified
            };
            let actual = meshopt::analyze_vertex_cache(&result, count, 16, 0, 0);
            Ok(json!({"toolVersion": VERSION, "indices": result,
                "inputTriangles": indices.len()/3, "outputTriangles": result.len()/3,
                "absoluteError": error, "errorMethod": "meshoptimizer-quadric-object-space",
                "cacheAcmrBefore": before.acmr, "cacheAcmrAfter": actual.acmr,
                "indexBytesBefore": indices.len()*4, "indexBytesAfter": result.len()*4,
                "vertexDataChanged": false}))
        }
        Request::Texture {
            width,
            height,
            rgba,
            srgb,
            mipmaps,
            format,
            quality,
            effort,
        } => {
            if width == 0
                || height == 0
                || width > 4096
                || height > 4096
                || !(1..=100).contains(&quality)
                || !(0..=10).contains(&effort)
            {
                return Err("invalid texture extent or quality".into());
            }
            let pixels = STANDARD.decode(rgba).map_err(|_| "invalid RGBA encoding")?;
            if pixels.len() != width as usize * height as usize * 4 {
                return Err("RGBA extent mismatch".into());
            }
            let format = match format.as_str() {
                "etc1s" => BasisTextureFormat::Etc1s,
                "uastc" => BasisTextureFormat::UastcLdr4x4,
                _ => return Err("unsupported texture profile".into()),
            };
            basisu_encoder_init();
            basisu_encoder_enable_debug_printf(false);
            let mut encoder = BasisuEncoder::new();
            encoder
                .set_image(SourceImage {
                    data: &pixels,
                    format: SourceImageFormat::Rgba8,
                    size: Extent3d {
                        width,
                        height,
                        depth_or_array_layers: 1,
                    },
                })
                .map_err(|_| "encoder image admission failed")?;
            let mut params = if srgb {
                BasisuEncoderParams::new_with_srgb_defaults(format)
            } else {
                BasisuEncoderParams::new_with_linear_defaults(format)
            };
            params = params.with_removed_flags(
                common::BU_COMP_FLAGS_THREADED | common::BU_COMP_FLAGS_KTX2_UASTC_ZSTD,
            );
            if mipmaps {
                params = params.with_flags(common::BU_COMP_FLAGS_GEN_MIPS_CLAMP);
            }
            params.quality_level = quality;
            params.effort_level = effort;
            let bytes = encoder
                .compress(params)
                .map_err(|_| "Basis compression failed")?;
            Ok(
                json!({"toolVersion": VERSION, "ktx2": STANDARD.encode(&bytes), "sourceBytes": pixels.len(),
                "encodedBytes": bytes.len(), "width": width, "height": height, "srgb": srgb, "mipmaps": mipmaps}),
            )
        }
    }
}
fn main() {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("{VERSION}");
        return;
    }
    let mut input = Vec::new();
    let result = io::stdin()
        .take(96 * 1024 * 1024 + 1)
        .read_to_end(&mut input)
        .map_err(|_| "input read failed".to_string())
        .and_then(|_| {
            if input.len() > 96 * 1024 * 1024 {
                Err("input budget exceeded".into())
            } else {
                Ok(())
            }
        })
        .and_then(|_| {
            serde_json::from_slice(&input).map_err(|_| "invalid preparation request".to_string())
        })
        .and_then(prepare);
    match result {
        Ok(result) => println!("{result}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_unknown_fields_and_out_of_range_mesh() {
        assert!(
            serde_json::from_value::<Request>(
                json!({"operation":"mesh","positions":[],"indices":[],"shell":"no"})
            )
            .is_err()
        );
        let request: Request = serde_json::from_value(
            json!({"operation":"mesh","positions":[0,0,0,1,0,0,0,1,0],"indices":[0,1,9]}),
        )
        .unwrap();
        assert!(prepare(request).is_err());
    }
    #[test]
    fn reordering_retains_oriented_triangles() {
        let request: Request = serde_json::from_value(
            json!({"operation":"mesh","positions":[0,0,0,1,0,0,0,1,0],"indices":[0,1,2]}),
        )
        .unwrap();
        let output = prepare(request).unwrap();
        assert_eq!(output["indices"], json!([0, 1, 2]));
        assert_eq!(output["absoluteError"], 0.0);
        assert_eq!(output["toolVersion"], VERSION);
    }
    #[test]
    fn texture_extent_must_match_payload() {
        let request: Request = serde_json::from_value(json!({"operation":"texture","width":16,"height":16,"rgba":"AA==","srgb":true,"mipmaps":true,"format":"uastc","quality":75,"effort":2})).unwrap();
        assert!(prepare(request).is_err());
    }
}
