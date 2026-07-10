import Testing
@testable import ProxyLight

private func engine(_ ms: [(String, String, Bool)]) -> MappingEngine {
	MappingEngine(mappings: ms.map { Mapping(from: $0.0, to: $0.1, enabled: $0.2) })
}

@Test func wildcardCapturesRemainderAndQuery() {
	let e = engine([("https://a.dev/tachyon/*", "https://a.org/tachyon/*", true)])
	let r = e.rewrite(scheme: "https", host: "a.dev", port: 443, uri: "/tachyon/2024/p.jpg?w=600")
	#expect(r == RewriteResult(scheme: "https", host: "a.org", port: 443, uri: "/tachyon/2024/p.jpg?w=600"))
}

@Test func exactPathMappingRequiresExactMatch() {
	let e = engine([("https://a.dev/health", "https://a.org/status", true)])
	#expect(e.rewrite(scheme: "https", host: "a.dev", port: 443, uri: "/health") ==
		RewriteResult(scheme: "https", host: "a.org", port: 443, uri: "/status"))
	#expect(e.rewrite(scheme: "https", host: "a.dev", port: 443, uri: "/health/x") == nil)
}

@Test func longestPrefixWins() {
	let e = engine([
		("https://a.dev/*", "https://broad.org/*", true),
		("https://a.dev/tachyon/*", "https://narrow.org/tachyon/*", true),
	])
	let r = e.rewrite(scheme: "https", host: "a.dev", port: 443, uri: "/tachyon/x.jpg")
	#expect(r?.host == "narrow.org")
}

@Test func schemeHostPortMustMatch() {
	let e = engine([("https://a.dev/x/*", "https://a.org/x/*", true)])
	#expect(e.rewrite(scheme: "http", host: "a.dev", port: 80, uri: "/x/y") == nil)
	#expect(e.rewrite(scheme: "https", host: "b.dev", port: 443, uri: "/x/y") == nil)
	#expect(e.rewrite(scheme: "https", host: "a.dev", port: 8443, uri: "/x/y") == nil)
}

@Test func disabledMappingIsIgnored() {
	let e = engine([("https://a.dev/x/*", "https://a.org/x/*", false)])
	#expect(e.rewrite(scheme: "https", host: "a.dev", port: 443, uri: "/x/y") == nil)
}

@Test func explicitPortInPatternMatches() {
	let e = engine([("http://a.dev:8080/x/*", "http://a.org:9090/x/*", true)])
	let r = e.rewrite(scheme: "http", host: "a.dev", port: 8080, uri: "/x/y")
	#expect(r == RewriteResult(scheme: "http", host: "a.org", port: 9090, uri: "/x/y"))
}

@Test func hostMatchingIsCaseInsensitive() {
	let e = engine([("https://Example.COM/x/*", "https://a.org/x/*", true)])
	let r = e.rewrite(scheme: "https", host: "example.com", port: 443, uri: "/x/y")
	#expect(r == RewriteResult(scheme: "https", host: "a.org", port: 443, uri: "/x/y"))
}

@Test func validMappingWithMatchingWildcardsIsValid() {
	#expect(validateMapping(from: "https://a.dev/x/*", to: "https://b.dev/x/*") == nil)
}

@Test func validExactMappingWithNoWildcardIsValid() {
	#expect(validateMapping(from: "https://a.dev/health", to: "https://b.dev/status") == nil)
}

@Test func wildcardOnlyOnOneSideIsMismatch() {
	#expect(validateMapping(from: "https://a.dev/x/*", to: "https://b.dev/x") == .wildcardMismatch)
}

@Test func nonHTTPSchemeIsInvalid() {
	guard case .fromInvalid = validateMapping(from: "ftp://a.dev/x/*", to: "https://b.dev/x/*") else {
		Issue.record("expected .fromInvalid for a non-http(s) scheme")
		return
	}
	guard case .toInvalid = validateMapping(from: "https://a.dev/x/*", to: "ftp://b.dev/x/*") else {
		Issue.record("expected .toInvalid for a non-http(s) scheme")
		return
	}
}

@Test func wildcardInMiddleOfPathIsInvalid() {
	guard case .fromInvalid = validateMapping(from: "https://a.dev/x*/y", to: "https://b.dev/x/y") else {
		Issue.record("expected .fromInvalid for '*' not at the end of the path")
		return
	}
}

@Test func pacHostnamesListsEnabledFromHostsSortedAndDeduplicated() {
	let engine = MappingEngine(mappings: [
		Mapping(from: "https://Zeta.Example.com/a/*", to: "https://r.example.net/a/*"),
		Mapping(from: "https://alpha.example.com/b/*", to: "https://r.example.net/b/*"),
		Mapping(from: "http://alpha.example.com/c/*", to: "http://r.example.net/c/*"),
	])
	#expect(engine.pacHostnames == ["alpha.example.com", "zeta.example.com"])
}

@Test func pacHostnamesExcludesDisabledMappings() {
	let engine = MappingEngine(mappings: [
		Mapping(from: "https://off.example.com/a/*", to: "https://r.example.net/a/*", enabled: false),
	])
	#expect(engine.pacHostnames.isEmpty)
}
