// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DriveGauge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DriveGauge", targets: ["DriveGauge"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "DriveSMART",
            path: "Sources/DriveSMART",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "DriveGauge",
            dependencies: ["DriveSMART", "CSQLite"],
            path: "Sources/DriveGauge"
        )
    ]
)
