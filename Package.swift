// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ProxyLight",
	platforms: [.macOS(.v14)],
	dependencies: [
		.package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
		.package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
		.package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.0"),
	],
	targets: [
		.executableTarget(
			name: "ProxyLight",
			dependencies: [
				.product(name: "NIOCore", package: "swift-nio"),
				.product(name: "NIOPosix", package: "swift-nio"),
				.product(name: "NIOHTTP1", package: "swift-nio"),
				.product(name: "NIOSSL", package: "swift-nio-ssl"),
				.product(name: "X509", package: "swift-certificates"),
			]
		),
		.testTarget(
			name: "ProxyLightTests",
			dependencies: [
				"ProxyLight",
				.product(name: "NIOEmbedded", package: "swift-nio"),
			]
		),
	]
)
