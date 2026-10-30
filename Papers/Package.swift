// swift-tools-version: 5.9
// The Papers test harness: compiles the app's shared code (Papers/Core) for macOS with llama.cpp and sherpa-onnx,
// so .github/workflows/papers-eval.yml can run the real pipeline on real papers and audio. The app itself is built
// from project.yml with XcodeGen; this package is only for testing.
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
// llama.cpp built for macOS: include/ (llama.h, ggml*.h) and lib/libllama-all.a
let llama = ProcessInfo.processInfo.environment["LLAMA_DIR"] ?? "\(root)/.llama"

let package = Package(
    name: "PapersHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "2.0.1"),
    ],
    targets: [
        .target(
            name: "ChatEngineC",
            path: "Papers/Engine/ChatEngine",
            sources: ["ChatEngine.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I\(llama)/include"])]
        ),
        .executableTarget(
            name: "papers-harness",
            dependencies: ["ChatEngineC", .product(name: "sherpa-onnx", package: "sherpa-onnx")],
            path: "Papers/Core",
            linkerSettings: [
                .unsafeFlags(["-L\(llama)/lib", "-lllama-all"]),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
