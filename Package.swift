// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InterviewHelper",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "InterviewCore", targets: ["InterviewCore"]),
    ],
    targets: [
        .target(name: "InterviewCore"),
        .testTarget(name: "InterviewCoreTests", dependencies: ["InterviewCore"]),
    ]
)
