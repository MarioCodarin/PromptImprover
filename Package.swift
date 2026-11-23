// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PromptImprover",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PromptCore", targets: ["PromptCore"])
    ],
    targets: [
        // The prompt pipeline with no UI: stages, budgets, linter, parsing, transport.
        .target(name: "PromptCore", path: "Sources/PromptCore"),
        .executableTarget(name: "PromptImprover", dependencies: ["PromptCore"],
                          path: "Sources/PromptImprover")
    ]
)
