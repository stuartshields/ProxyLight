import Foundation

// Plain-Swift proxy control surface shared by every frontend (the macOS menu
// bar app and the Linux CLI): owns config persistence, the live mapping set,
// the CA, and the NIO listener. Has no SwiftUI/ObservableObject or
// system-proxy coupling — those are frontend-specific layers built on top.
public final class ProxyOrchestrator {
	public var config: AppConfig
	public private(set) var isRunning = false
	public private(set) var runningPort: Int?

	private let store: MappingStore
	private var ca: CertificateAuthority?
	private var server: ProxyServer?
	// Live mapping set read by the proxy's engineProvider closure from NIO
	// event-loop threads. Kept in sync with config.mappings on every save().
	private let mappingsBox = MappingsBox([])
	// Bumped on every mapping save while running, so a frontend that caches
	// the PAC by URL (e.g. macOS) can force a re-fetch by changing ?v=.
	private var pacVersion = 0

	public static var defaultDirectory: URL { MappingStore.defaultDirectory }

	public init(directory: URL) {
		store = MappingStore(directory: directory)
		config = store.load()
		ca = try? CertificateAuthority(directory: directory)
		mappingsBox.set(config.mappings)
	}

	public var rootCertificatePEM: String { ca?.rootCertificatePEM ?? "Certificate authority unavailable" }
	public var rootCertificateURL: URL? { ca?.rootCertificateURL }

	public func pacURL(host: String = "127.0.0.1") -> String? {
		guard let runningPort else { return nil }
		return "http://\(host):\(runningPort)/proxy.pac?v=\(pacVersion)"
	}

	public func start() throws -> Int {
		let engineProvider: @Sendable () -> MappingEngine = { [mappingsBox] in MappingEngine(mappings: mappingsBox.get()) }
		let server = ProxyServer(port: config.listenPort, engineProvider: engineProvider, ca: ca)
		let boundPort = try server.start()
		self.server = server
		pacVersion = 1
		runningPort = boundPort
		isRunning = true
		return boundPort
	}

	public func stop() throws {
		try server?.stop()
		server = nil
		runningPort = nil
		isRunning = false
	}

	public func addMapping(from: String, to: String, mode: MappingMode) {
		config.mappings.append(Mapping(from: from, to: to, enabled: true, mode: mode))
		save()
	}

	public func updateMapping(id: Mapping.ID, from: String, to: String, mode: MappingMode) {
		guard let index = config.mappings.firstIndex(where: { $0.id == id }) else { return }
		config.mappings[index].from = from
		config.mappings[index].to = to
		config.mappings[index].mode = mode
		save()
	}

	public func deleteMapping(_ id: Mapping.ID) {
		config.mappings.removeAll { $0.id == id }
		save()
	}

	public func exportData(_ selected: [Mapping]) throws -> Data {
		try MappingIO.encode(selected)
	}

	public func decodeImportFile(_ data: Data) throws -> [Mapping] {
		try MappingIO.decode(data)
	}

	public func completeImport(accepted: [Mapping]) -> MappingIO.ImportResult {
		let result = MappingIO.apply(existing: config.mappings, accepted: accepted)
		config.mappings = result.mappings
		save()
		return result
	}

	public func save() {
		mappingsBox.set(config.mappings)
		try? store.save(config)
		if isRunning { pacVersion += 1 }
	}
}
