#[path = "../tests/support/draco_fixture.rs"]
mod fixture;

fn main() {
    let directory =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test_assets/compression");
    std::fs::create_dir_all(&directory).unwrap();
    for (speed, name) in [(0, "quad-edgebreaker.drc"), (10, "quad-sequential.drc")] {
        std::fs::write(directory.join(name), fixture::encoded(speed)).unwrap();
    }
}
