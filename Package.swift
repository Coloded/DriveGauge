// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DriveGauge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DriveGauge", targets: ["DriveGauge"]),
        .executable(name: "DriveGaugeNetworkWorker", targets: ["DriveGaugeNetworkWorker"]),
        .executable(name: "NetworkBenchmarkSelfTests", targets: ["NetworkBenchmarkSelfTests"])
    ],
    targets: [
        .target(
            name: "NetworkBenchmarkProtocol",
            path: "Sources/NetworkBenchmarkProtocol"
        ),
        .target(
            name: "BenchmarkPersistence",
            dependencies: ["CSQLite"],
            path: "Sources/BenchmarkPersistence"
        ),
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
            dependencies: ["DriveSMART", "CSQLite", "NetworkBenchmarkProtocol", "BenchmarkPersistence"],
            path: "Sources/DriveGauge"
        ),
        .executableTarget(
            name: "DriveGaugeNetworkWorker",
            dependencies: ["NetworkBenchmarkProtocol"],
            path: "Sources/DriveGaugeNetworkWorker"
        ),
        .executableTarget(
            name: "NetworkBenchmarkSelfTests",
            dependencies: ["NetworkBenchmarkProtocol", "BenchmarkPersistence", "CSQLite"],
            path: "Tests/NetworkBenchmarkProtocolTests"
        )
    ]
)
