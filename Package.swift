// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PaperCat",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            path: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .executableTarget(
            name: "PaperCat",
            dependencies: ["CLibUSB"],
            path: ".",
            exclude: [
                "Package.swift",
                "CLibUSB",
                "Tests",
                "PROTOCOL_FINDINGS.md",
                "README.md",
                "Info.plist",
                "Entitlements.plist",
                "AppIcon.icns",
                "AppIcon.iconset",
                "build-app.sh",
                "HPScannerApp",
                "PaperCat.app",
                ".vscode",
                ".gitignore",
            ],
            sources: [
                "PaperCatApp.swift",
                "Models",
                "Services",
                "Utilities",
                "ViewModels",
                "Views",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-framework", "Vision",
                    "-framework", "PDFKit",
                    "-framework", "CoreImage",
                    "-framework", "AppKit",
                    "-L/opt/homebrew/lib",
                ]),
                .linkedLibrary("usb-1.0"),
            ]
        )
    ]
)
