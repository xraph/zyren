use e57::{Record, RecordDataType, RecordName, RecordValue};
use las::{
    Builder, Color, Point, Transform, Vlr,
    point::{Classification, Format},
};
use std::{fs::File, io::Cursor, path::Path};
fn main() {
    let dir = std::env::args().nth(1).expect("fixture directory");
    for (format, compressed, name) in [
        (3, false, "survey.las"),
        (3, true, "survey.laz"),
        (7, true, "survey14.laz"),
    ] {
        let mut builder = Builder::from((1, 4));
        builder.point_format = Format::new(format).unwrap();
        builder.point_format.is_compressed = compressed;
        builder.transforms.x = Transform {
            scale: 0.001,
            offset: 1_000_000_000.,
        };
        builder.transforms.y = Transform {
            scale: 0.001,
            offset: -2_000_000.,
        };
        builder.transforms.z = Transform {
            scale: 0.001,
            offset: 20.,
        };
        builder.vlrs.push(Vlr {
            user_id: "LASF_Projection".into(),
            record_id: 2112,
            description: "Local test CRS".into(),
            data: b"LOCAL_CS[\"Fixture\"]\0".to_vec(),
        });
        let mut writer =
            las::Writer::new(Cursor::new(Vec::new()), builder.into_header().unwrap()).unwrap();
        for i in 0..3 {
            writer
                .write_point(Point {
                    x: 1_000_000_000. + i as f64 * 0.001,
                    y: -2_000_000. + i as f64,
                    z: 20. + i as f64,
                    intensity: 1200 + i,
                    return_number: 1,
                    number_of_returns: 2,
                    classification: Classification::new(2).unwrap(),
                    is_withheld: i == 2,
                    gps_time: Some(123456. + i as f64),
                    color: Some(Color::new(65535, 32768, i)),
                    ..Default::default()
                })
                .unwrap();
        }
        let bytes = writer.into_inner().unwrap().into_inner();
        std::fs::write(Path::new(&dir).join(name), bytes).unwrap();
    }
    let file = File::create(Path::new(&dir).join("scans.e57")).unwrap();
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(Path::new(&dir).join("scans.e57"))
        .unwrap_or(file);
    let mut writer = e57::E57Writer::new(file, "fixture-file-001").unwrap();
    writer.set_coordinate_metadata(Some("LOCAL_CS[\"Fixture\"]".into()));
    for scan in 0..2 {
        let prototype = vec![
            Record {
                name: RecordName::CartesianX,
                data_type: RecordDataType::ScaledInteger {
                    min: -100000,
                    max: 100000,
                    scale: 0.001,
                    offset: 10.,
                },
            },
            Record {
                name: RecordName::CartesianY,
                data_type: RecordDataType::Double {
                    min: None,
                    max: None,
                },
            },
            Record {
                name: RecordName::CartesianZ,
                data_type: RecordDataType::Double {
                    min: None,
                    max: None,
                },
            },
            Record {
                name: RecordName::CartesianInvalidState,
                data_type: RecordDataType::Integer { min: 0, max: 2 },
            },
            Record {
                name: RecordName::Intensity,
                data_type: RecordDataType::Double {
                    min: None,
                    max: None,
                },
            },
            Record {
                name: RecordName::ReturnIndex,
                data_type: RecordDataType::Integer { min: 0, max: 2 },
            },
            Record {
                name: RecordName::ReturnCount,
                data_type: RecordDataType::Integer { min: 1, max: 3 },
            },
        ];
        let mut pc = writer
            .add_pointcloud(&format!("fixture-scan-{scan}"), prototype)
            .unwrap();
        pc.set_name(Some(format!("Scan {scan}")));
        pc.set_transform(Some(e57::Transform {
            rotation: e57::Quaternion {
                w: 1.,
                x: 0.,
                y: 0.,
                z: 0.,
            },
            translation: e57::Translation {
                x: 100. + scan as f64 * 10.,
                y: 0.,
                z: 0.,
            },
        }));
        for i in 0..3 {
            pc.add_point(vec![
                RecordValue::ScaledInteger(i),
                RecordValue::Double(2.),
                RecordValue::Double(3.),
                RecordValue::Integer(if i == 1 { 2 } else { 0 }),
                RecordValue::Double(0.12345678912345),
                RecordValue::Integer(1),
                RecordValue::Integer(2),
            ])
            .unwrap();
        }
        pc.finalize().unwrap();
    }
    writer.finalize().unwrap();
}
