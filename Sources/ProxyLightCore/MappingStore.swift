import Foundation

struct MappingStore {
	private let fileURL: URL

	init(directory: URL) {
		fileURL = directory.appendingPathComponent("config.json")
	}

	static var defaultDirectory: URL {
		defaultDirectory(environment: ProcessInfo.processInfo.environment)
	}

	static func defaultDirectory(environment: [String: String]) -> URL {
		#if os(macOS)
		return FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ProxyLight", isDirectory: true)
		#else
		if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
			return URL(fileURLWithPath: xdgConfigHome).appendingPathComponent("proxylight", isDirectory: true)
		}
		let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
		return URL(fileURLWithPath: home).appendingPathComponent(".config/proxylight", isDirectory: true)
		#endif
	}

	func load() -> AppConfig {
		guard let data = try? Data(contentsOf: fileURL),
			let config = try? JSONDecoder().decode(AppConfig.self, from: data)
		else { return .defaultConfig }
		return config
	}

	func save(_ config: AppConfig) throws {
		try FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try encoder.encode(config).write(to: fileURL, options: .atomic)
	}
}
