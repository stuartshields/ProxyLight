import Foundation

// A shareable bundle of mappings (versioned for forward-compatibility).
struct MappingBundle: Codable, Equatable {
	var version: Int
	var mappings: [Mapping]
}

// Import/export of mappings so a config can be shared between people.
// Pure and I/O-free — the UI layer handles file panels and disk access.
enum MappingIO {
	static let currentVersion = 1

	static func encode(_ mappings: [Mapping]) throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		return try encoder.encode(MappingBundle(version: currentVersion, mappings: mappings))
	}

	// Accepts either the versioned bundle or a bare array of mappings, so a
	// hand-written or older file still imports.
	static func decode(_ data: Data) throws -> [Mapping] {
		let decoder = JSONDecoder()
		if let bundle = try? decoder.decode(MappingBundle.self, from: data) {
			return bundle.mappings
		}
		return try decoder.decode([Mapping].self, from: data)
	}

	// Appends imported mappings that aren't already present (matched on
	// from/to/mode), giving each a fresh id so ids never collide. Returns the
	// merged list; existing mappings are untouched, so import is non-destructive.
	static func merge(existing: [Mapping], imported: [Mapping]) -> [Mapping] {
		func key(_ m: Mapping) -> String { "\(m.from)\u{0}\(m.to)\u{0}\(m.mode.rawValue)" }
		var seen = Set(existing.map(key))
		var result = existing
		for m in imported where !seen.contains(key(m)) {
			seen.insert(key(m))
			result.append(Mapping(from: m.from, to: m.to, enabled: m.enabled, mode: m.mode))
		}
		return result
	}
}
