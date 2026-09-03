// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoNoiseMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NoNoiseMac", targets: ["NoNoiseMac"])
    ],
    targets: [
        // Lock-free C11-atomics SPSC float ring for the tap-based Clean Incoming path (bridges the
        // process-tap IOProc → AVAudioSourceNode, two realtime threads). C target because acquire/
        // release atomics aren't available pure-Swift on the macOS 14.4 floor; mirrors the driver's
        // tested nn_ring discipline with zero external dependencies.
        .target(
            name: "CTapRing",
            path: "Sources/CTapRing"
        ),
        // Objective-C shim: catches NSExceptions from AVAudioEngine graph calls (Swift cannot).
        // See Sources/CExceptionGuard/include/nn_exception_guard.h for the field-crash rationale.
        .target(
            name: "CExceptionGuard",
            path: "Sources/CExceptionGuard"
        ),
        .target(
            name: "Core",
            dependencies: ["CTapRing", "CExceptionGuard"],
            path: "Sources/Core",
            resources: [
                .copy("../../Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreML"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(
            name: "NoNoiseMac",
            dependencies: [
                "Core"
            ],
            path: "Sources/App",
            resources: [
                .process("../../Resources")
            ],
            linkerSettings: [
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "NoNoiseMacCLI",
            dependencies: ["Core"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "NoNoiseMacTests",
            dependencies: ["Core", "CTapRing"],
            path: "Tests/NoNoiseMacTests"
        )
    ]
)
