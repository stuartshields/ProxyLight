import Foundation

struct MappingStore {
	private let fileURL: URL

	init(directory: URL) {
		fileURL = directory.appendingPathComponent("config.json")
	}

	static var defaultDirectory: URL {
		FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("ProxyLight", isDirectory: true)
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
