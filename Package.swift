// swift-tools-version: 6.0
import PackageDescription

// The ScopeApp target holds the SwiftUI app; the OwonScopeMac executable starts it.
let package = Package(
    name: "OwonScope",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "OwonScopeMac", targets: ["OwonScope"]),
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
        .target(
            name: "ScopeApp",
            dependencies: ["ScopeKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OwonScope",
            dependencies: ["ScopeApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
