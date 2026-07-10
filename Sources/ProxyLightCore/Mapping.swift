import Foundation

// How a matched request is routed.
// - rewrite: always forward to the remote target (the original behavior).
// - fallbackOnNotFound: serve the LOCAL origin first; only forward to the remote
//   target if the local response is 404 (for safe GET/HEAD requests).
public enum MappingMode: String, Codable, CaseIterable, Sendable {
	case rewrite
	case fallbackOnNotFound
}

public struct Mapping: Codable, Identifiable, Equatable, Sendable {
	public var id: UUID
	public var from: String
	public var to: String
	public var enabled: Bool
	public var mode: MappingMode

	public init(id: UUID = UUID(), from: String, to: String, enabled: Bool = true, mode: MappingMode = .rewrite) {
		self.id = id
		self.from = from
		self.to = to
		self.enabled = enabled
		self.mode = mode
	}

	// Custom decode so configs written before `mode` existed still load: a
	// missing `mode` key defaults to .rewrite (the prior behavior).
	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(UUID.self, forKey: .id)
		from = try c.decode(String.self, forKey: .from)
		to = try c.decode(String.self, forKey: .to)
		enabled = try c.decode(Bool.self, forKey: .enabled)
		mode = try c.decodeIfPresent(MappingMode.self, forKey: .mode) ?? .rewrite
	}
}

public struct AppConfig: Codable, Equatable, Sendable {
	public var listenPort: Int
	public var mappings: [Mapping]

	public static var defaultConfig: AppConfig {
		AppConfig(listenPort: 9876, mappings: [])
	}
}

public enum MappingValidationError: Equatable {
	case fromInvalid(String)
	case toInvalid(String)
	case wildcardMismatch

	// User-facing message shared by every place that surfaces a validation
	// failure (the mappings list and the add-mapping modal).
	public var message: String {
		switch self {
		case .fromInvalid(let reason): return "From: \(reason)"
		case .toInvalid(let reason): return "To: \(reason)"
		case .wildcardMismatch: return "From and To must agree on whether they use '*'"
		}
	}
}

// Pure validator mirroring MappingEngine's parsing rules, so bad patterns can
// be flagged in the UI instead of being silently dropped at engine-build time.
// Returns nil when the pair is valid, else the first problem found.
public func validateMapping(from: String, to: String) -> MappingValidationError? {
	if let reason = urlValidationProblem(from) {
		return .fromInvalid(reason)
	}
	if let reason = urlValidationProblem(to) {
		return .toInvalid(reason)
	}
	if hasTrailingWildcard(from) != hasTrailingWildcard(to) {
		return .wildcardMismatch
	}
	return nil
}

private func urlValidationProblem(_ pattern: String) -> String? {
	guard let comps = URLComponents(string: pattern),
		let scheme = comps.scheme?.lowercased(),
		scheme == "http" || scheme == "https"
	else { return "must be a valid http(s) URL" }
	guard let host = comps.host, !host.isEmpty else { return "must include a host" }

	let path = comps.path
	let wildcardCount = path.filter { $0 == "*" }.count
	if wildcardCount > 1 || (wildcardCount == 1 && !path.hasSuffix("*")) {
		return "'*' may appear only as the final character of the path"
	}
	return nil
}

private func hasTrailingWildcard(_ pattern: String) -> Bool {
	URLComponents(string: pattern)?.path.hasSuffix("*") ?? false
}
