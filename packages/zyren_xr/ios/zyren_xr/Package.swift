// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "zyren_xr",
    platforms: [.iOS(.v14)],
    products: [.library(name: "zyren-xr", targets: ["zyren_xr"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [.target(name: "zyren_xr", dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")], path: "Sources/zyren_xr",
        linkerSettings: [.linkedFramework("ARKit"), .linkedFramework("AVFoundation"),
            .linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("CoreVideo")])]
)
