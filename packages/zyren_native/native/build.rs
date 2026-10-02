fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        // Keep codec exceptions inside this library. Android's system
        // libstdc++ stub does not provide the NDK C++ exception ABI.
        let output = cc::Build::new()
            .cpp(true)
            .get_compiler()
            .to_command()
            .arg("-print-file-name=libc++_static.a")
            .output()
            .expect("locate the Android NDK C++ runtime");
        assert!(
            output.status.success(),
            "NDK compiler could not locate libc++"
        );
        let path = String::from_utf8(output.stdout).expect("NDK runtime path is UTF-8");
        let path = std::path::Path::new(path.trim());
        assert!(path.is_file(), "NDK libc++ static archive is missing");
        // Do not expose the sysroot directory to Rust's linker search. It
        // also contains static bionic archives, which must stay dynamic.
        let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
        for name in ["libc++_static.a", "libc++abi.a"] {
            std::fs::copy(path.parent().unwrap().join(name), out.join(name))
                .expect("copy the NDK C++ runtime archive");
        }
        println!("cargo:rustc-link-search=native={}", out.display());
        println!("cargo:rustc-link-lib=static=c++_static");
        println!("cargo:rustc-link-lib=static=c++abi");
        println!("cargo:rustc-link-arg=-Wl,--no-undefined");
    }
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
