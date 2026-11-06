// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacNotepad",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacNotepad",
            targets: ["MacNotepad"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MacNotepad",
            path: "Sources/MacNotepad"
        ),
        .testTarget(
            name: "MacNotepadTests",
            dependencies: ["MacNotepad"],
            path: "Tests/MacNotepadTests"
        )
    ]
)
