// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacExplorer",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "MacExplorer", targets: ["MacExplorer"]),
    ],
    dependencies: [
        // FTP / FTPS / SFTP: MacZilla ile ortak FTPKit (aynı geliştirici, GPL-3.0). Belirli bir commit'e sabit.
        .package(url: "https://gitlab.com/freeware2/maczilla.git", revision: "ea2bf909aa00b8758f0767617d044d3f959a5428"),
    ],
    targets: [
        // Arayüzden bağımsız çekirdek: klasör okuma, sıralama, gezinme geçmişi, klasör izleme.
        .target(name: "MacExplorerCore"),
        // AppKit arayüzü.
        .executableTarget(name: "MacExplorer", dependencies: [
            "MacExplorerCore",
            .product(name: "FTPKit", package: "maczilla"),
        ]),
        .testTarget(name: "MacExplorerCoreTests", dependencies: ["MacExplorerCore"]),
    ]
)
