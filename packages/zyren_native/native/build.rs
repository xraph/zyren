fn main() {
    println!("cargo:rerun-if-changed=src/interop/apple_buffer.mm");
    if std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() == Ok("apple") {
        let mut build = cc::Build::new();
        // cc otherwise uses the installed SDK version as the deployment floor.
        let (key, minimum) = match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
            Ok("ios") => ("IPHONEOS_DEPLOYMENT_TARGET", "13.0"),
            _ => ("MACOSX_DEPLOYMENT_TARGET", "11.0"),
        };
        if std::env::var_os(key).is_none() {
            build.env(key, minimum);
        }
        build
            .cpp(true)
            .file("src/interop/apple_buffer.mm")
            .flag("-fobjc-arc")
            .flag("-std=c++17")
            .compile("zyren_apple_buffer");
        for framework in ["Foundation", "CoreVideo", "IOSurface", "Metal"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    }
}
