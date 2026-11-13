// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OwonScope",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "OwonScope", targets: ["OwonScope"]),
        .library(name: "ScopeKit", targets: ["ScopeKit"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(
            name: "ScopeKit",
            dependencies: ["CLibUSB"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OwonScope",
            dependencies: ["ScopeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
