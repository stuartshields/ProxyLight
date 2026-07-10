import Testing
import Foundation
@testable import ProxyLightCore

@Test func appConfigRoundTrips() throws {
	let config = AppConfig(listenPort: 9876, mappings: [
		Mapping(id: UUID(), from: "https://a.dev/x/*", to: "https://a.org/x/*", enabled: true),
	])
	let data = try JSONEncoder().encode(config)
	let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
	#expect(decoded == config)
}

@Test func defaultConfigListensOn9876() {
	#expect(AppConfig.defaultConfig.listenPort == 9876)
	#expect(AppConfig.defaultConfig.mappings.isEmpty)
}

@Test func storeSavesAndLoads() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: dir) }

	let store = MappingStore(directory: dir)
	let config = AppConfig(listenPort: 1234, mappings: [
		Mapping(from: "https://a.dev/*", to: "https://a.org/*", enabled: true),
	])
	try store.save(config)
	#expect(store.load() == config)
}

@Test func loadReturnsDefaultWhenMissing() {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	#expect(MappingStore(directory: dir).load() == AppConfig.defaultConfig)
}

@Test func loadToleratesMalformedFile() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: dir) }
	try Data("{ not json".utf8).write(to: dir.appendingPathComponent("config.json"))
	#expect(MappingStore(directory: dir).load() == AppConfig.defaultConfig)
}

@Test func mappingIORoundTrips() throws {
	let ms = [
		Mapping(from: "https://a.dev/x/*", to: "https://a.org/x/*", enabled: true, mode: .fallbackOnNotFound),
		Mapping(from: "https://b.dev/y", to: "https://b.org/y", enabled: false, mode: .rewrite),
	]
	let decoded = try MappingIO.decode(MappingIO.encode(ms))
	#expect(decoded.count == 2)
	#expect(decoded[0].from == "https://a.dev/x/*")
	#expect(decoded[0].mode == .fallbackOnNotFound)
	#expect(decoded[1].enabled == false)
}

@Test func mappingIODecodesBareArrayWithoutMode() throws {
	let json = #"[{"id":"637E088C-0DA9-408D-844E-55E94C136211","from":"https://a.dev/x/*","to":"https://a.org/x/*","enabled":true}]"#
	let decoded = try MappingIO.decode(Data(json.utf8))
	#expect(decoded.count == 1)
	#expect(decoded[0].mode == .rewrite)
}

// MARK: Import classification & selective apply

private func m(_ from: String, _ to: String, mode: MappingMode = .rewrite, enabled: Bool = true) -> Mapping {
	Mapping(from: from, to: to, enabled: enabled, mode: mode)
}

@Test func classifyMarksExactContentMatchAsDuplicate() {
	let existing = [m("https://a.dev/x/*", "https://a.org/x/*")]
	#expect(MappingIO.classify(m("https://a.dev/x/*", "https://a.org/x/*"), against: existing) == .duplicate)
}

@Test func classifyIgnoresEnabledFlagForDuplicates() {
	let existing = [m("https://a.dev/x/*", "https://a.org/x/*", enabled: false)]
	#expect(MappingIO.classify(m("https://a.dev/x/*", "https://a.org/x/*"), against: existing) == .duplicate)
}

@Test func classifyMarksSharedFromAsConflict() {
	let existing = [m("https://a.dev/x/*", "https://a.org/x/*")]
	let disposition = MappingIO.classify(m("https://a.dev/x/*", "https://other.org/x/*"), against: existing)
	#expect(disposition == .conflict(existing))
}

@Test func classifyMarksSharedToAsConflict() {
	let existing = [m("https://a.dev/x/*", "https://a.org/x/*")]
	let disposition = MappingIO.classify(m("https://other.dev/x/*", "https://a.org/x/*"), against: existing)
	#expect(disposition == .conflict(existing))
}

@Test func classifyMarksModeChangeAsConflict() {
	// Same from/to but a different mode isn't an exact duplicate — the user
	// must decide whether the imported mode wins.
	let existing = [m("https://a.dev/x/*", "https://a.org/x/*", mode: .rewrite)]
	let disposition = MappingIO.classify(m("https://a.dev/x/*", "https://a.org/x/*", mode: .fallbackOnNotFound), against: existing)
	#expect(disposition == .conflict(existing))
}

@Test func classifyMarksUnrelatedAsNew() {
	let existing = [m("https://a.dev/x/*", "https://a.org/x/*")]
	#expect(MappingIO.classify(m("https://b.dev/*", "https://b.org/*"), against: existing) == .new)
}

@Test func applyAddsNewSkipsDuplicatesOverwritesConflicts() throws {
	let a = m("https://a.dev/x/*", "https://a.org/x/*")
	let b = m("https://b.dev/y/*", "https://b.org/y/*")
	let accepted = [
		m("https://a.dev/x/*", "https://a.org/x/*"), // duplicate of a
		m("https://b.dev/y/*", "https://new.org/y/*", mode: .fallbackOnNotFound), // same from as b
		m("https://c.dev/z/*", "https://c.org/z/*"), // new
	]
	let result = MappingIO.apply(existing: [a, b], accepted: accepted)
	#expect(result.added == 1)
	#expect(result.replaced == 1)
	#expect(result.unchanged == 1)
	try #require(result.mappings.count == 3)
	#expect(result.mappings[0] == a) // untouched
	#expect(result.mappings[1].id == b.id) // overwritten in place, id stable
	#expect(result.mappings[1].to == "https://new.org/y/*")
	#expect(result.mappings[1].mode == .fallbackOnNotFound)
	let added = result.mappings[2]
	#expect(added.from == "https://c.dev/z/*")
	#expect(added.id != accepted[2].id) // fresh id, never the imported file's id
}

@Test func applyOverwriteConsumesEveryConflictingExisting() throws {
	// The imported mapping's from matches one existing and its to matches
	// another: overwrite replaces both with the single imported mapping.
	let a = m("https://a.dev/x/*", "https://a.org/x/*")
	let b = m("https://b.dev/y/*", "https://b.org/y/*")
	let result = MappingIO.apply(existing: [a, b], accepted: [m("https://a.dev/x/*", "https://b.org/y/*")])
	try #require(result.mappings.count == 1)
	#expect(result.mappings[0].id == a.id)
	#expect(result.mappings[0].from == "https://a.dev/x/*")
	#expect(result.mappings[0].to == "https://b.org/y/*")
	#expect(result.replaced == 1)
}

@Test func applyLeavesExistingUntouchedWhenNothingAccepted() {
	let a = m("https://a.dev/x/*", "https://a.org/x/*")
	let result = MappingIO.apply(existing: [a], accepted: [])
	#expect(result.mappings == [a])
	#expect(result.added == 0 && result.replaced == 0 && result.unchanged == 0)
}

@Test func mappingWithoutModeFieldDecodesAsRewrite() throws {
	// Configs written before `mode` existed must still load (missing key →
	// .rewrite), or a user's saved mappings would be wiped on upgrade.
	let legacy = """
	{"id":"637E088C-0DA9-408D-844E-55E94C136211","from":"https://a.dev/x/*","to":"https://a.org/x/*","enabled":true}
	"""
	let mapping = try JSONDecoder().decode(Mapping.self, from: Data(legacy.utf8))
	#expect(mapping.mode == .rewrite)
	#expect(mapping.from == "https://a.dev/x/*")
	#expect(mapping.enabled)
}
