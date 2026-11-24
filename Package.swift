// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimplexRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SimplexRecorder",
            path: "Sources/SimplexRecorder",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
