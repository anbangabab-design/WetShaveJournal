// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WetShaveJournal",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WetShaveJournal", targets: ["WetShaveJournal"])
    ],
    targets: [
        .executableTarget(
            name: "WetShaveJournal",
            path: "Sources/WetShaveJournal"
        ),
        .testTarget(
            name: "WetShaveJournalTests",
            dependencies: ["WetShaveJournal"],
            path: "Tests/WetShaveJournalTests"
        )
    ]
)
