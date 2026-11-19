// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "TurbineMac",
  platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "TurbineMac", path: "Sources")]
)
