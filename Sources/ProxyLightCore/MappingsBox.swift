import Foundation

// Thread-safe holder for the live mapping set. AppState (main actor) writes it
// on every config change; the proxy's engineProvider closure reads it from NIO
// event-loop threads, so access is lock-guarded.
final class MappingsBox: @unchecked Sendable {
	private let lock = NSLock()
	private var mappings: [Mapping]

	init(_ mappings: [Mapping]) {
		self.mappings = mappings
	}

	func get() -> [Mapping] {
		lock.lock()
		defer { lock.unlock() }
		return mappings
	}

	func set(_ new: [Mapping]) {
		lock.lock()
		defer { lock.unlock() }
		mappings = new
	}
}
