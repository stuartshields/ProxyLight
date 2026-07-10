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

	// How one imported mapping relates to the current set.
	// - duplicate: identical from/to/mode already present — importing is a no-op.
	// - conflict: shares a from (local) or to (live site) URL with existing
	//   mappings, so importing it means overwriting those.
	enum ImportDisposition: Equatable {
		case new
		case duplicate
		case conflict([Mapping])
	}

	// Outcome of a selective import.
	struct ImportResult: Equatable {
		var mappings: [Mapping]
		var added: Int
		var replaced: Int
		var unchanged: Int
	}

	static func classify(_ imported: Mapping, against existing: [Mapping]) -> ImportDisposition {
		if existing.contains(where: { isSameContent($0, imported) }) {
			return .duplicate
		}
		let conflicts = existing.filter { $0.from == imported.from || $0.to == imported.to }
		return conflicts.isEmpty ? .new : .conflict(conflicts)
	}

	// Merges the accepted imported mappings into the existing list. Exact
	// duplicates are skipped; a conflicting import overwrites every existing
	// mapping it collides with (the first keeps its slot and id, extras are
	// removed); the rest are appended with fresh ids so ids never collide.
	static func apply(existing: [Mapping], accepted: [Mapping]) -> ImportResult {
		var result = ImportResult(mappings: existing, added: 0, replaced: 0, unchanged: 0)
		for imported in accepted {
			if result.mappings.contains(where: { isSameContent($0, imported) }) {
				result.unchanged += 1
				continue
			}
			let conflictIndices = result.mappings.indices.filter {
				result.mappings[$0].from == imported.from || result.mappings[$0].to == imported.to
			}
			if let first = conflictIndices.first {
				result.mappings[first] = Mapping(id: result.mappings[first].id,
					from: imported.from, to: imported.to, enabled: imported.enabled, mode: imported.mode)
				for index in conflictIndices.dropFirst().reversed() {
					result.mappings.remove(at: index)
				}
				result.replaced += 1
			} else {
				result.mappings.append(Mapping(from: imported.from, to: imported.to,
					enabled: imported.enabled, mode: imported.mode))
				result.added += 1
			}
		}
		return result
	}

	private static func isSameContent(_ a: Mapping, _ b: Mapping) -> Bool {
		a.from == b.from && a.to == b.to && a.mode == b.mode
	}
}
