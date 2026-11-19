// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "SidePad",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SidePad", targets: ["SidePad"])],
    targets: [
        .executableTarget(name: "SidePad", resources: [.process("Resources/AI")], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                          "-Xlinker", "__info_plist", "-Xlinker", "\(root)/Info.plist"])
        ]),
        .testTarget(name: "SidePadTests", dependencies: ["SidePad"])
    ],
    swiftLanguageModes: [.v5]
)
