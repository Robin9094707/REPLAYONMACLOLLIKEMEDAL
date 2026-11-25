// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimplexRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        // Tiny Objective-C bridge for virtual displays (iPhone as second screen).
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "SimplexRecorder",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/SimplexRecorder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
