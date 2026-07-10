import Foundation

// The system-proxy state to restore, plus the network service it applies to.
struct RestorePoint: Codable, Equatable {
	var service: String
	var state: ProxyState
}

// Persists a pending restore point across process lifetimes so the system proxy
// can be recovered even after an UNCLEAN exit (crash, SIGKILL, force-quit).
//
// Lifecycle: written just before the proxy is applied; deleted on a clean
// shutdown (toggle-off / Quit / signal). If a restore point is still present at
// the next launch, the previous session ended without cleaning up — so the
// system proxy may be stranded pointing at our dead listener, and we restore it.
struct ProxyRestoreStore {
	private let fileURL: URL

	init(directory: URL) {
		fileURL = directory.appendingPathComponent("pending-restore.json")
	}

	func load() -> RestorePoint? {
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		return try? JSONDecoder().decode(RestorePoint.self, from: data)
	}

	func save(_ point: RestorePoint) {
		try? FileManager.default.createDirectory(
			at: fileURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		guard let data = try? JSONEncoder().encode(point) else { return }
		try? data.write(to: fileURL, options: .atomic)
	}

	func clear() {
		try? FileManager.default.removeItem(at: fileURL)
	}
}
