import Testing
@testable import ProxyLight

@Test func pacRoutesMappedHostsThroughProxy() {
	let pac = PACGenerator.generate(hostnames: ["a.example.com", "b.example.com"], proxyPort: 9876)
	#expect(pac.contains("function FindProxyForURL(url, host)"))
	#expect(pac.contains("\"a.example.com\": 1"))
	#expect(pac.contains("\"b.example.com\": 1"))
	#expect(pac.contains("return \"PROXY 127.0.0.1:9876\""))
	#expect(pac.contains("return \"DIRECT\""))
	// Fail-loudly decision: mapped hosts get NO "; DIRECT" failover.
	#expect(!pac.contains("PROXY 127.0.0.1:9876; DIRECT"))
}

@Test func pacWithNoHostnamesReturnsDirectForEverything() {
	let pac = PACGenerator.generate(hostnames: [], proxyPort: 9876)
	#expect(pac.contains("var mapped = {  };") || pac.contains("var mapped = {};"))
	#expect(pac.contains("return \"DIRECT\""))
}

@Test func pacLowercasesHostnameKeysSoMixedCaseInputStillMatches() {
	let pac = PACGenerator.generate(hostnames: ["MixedCase.Example.com"], proxyPort: 9876)
	#expect(pac.contains("\"mixedcase.example.com\": 1"))
	#expect(!pac.contains("MixedCase.Example.com"))
}

@Test func pacEscapesQuotesAndBackslashesInHostnames() {
	// URLComponents-validated hosts can't contain these, but the generator
	// must not rely on that assumption holding forever.
	let pac = PACGenerator.generate(hostnames: [#"evil"host"#, #"back\slash"#], proxyPort: 1)
	#expect(pac.contains(#""evil\"host": 1"#))
	#expect(pac.contains(#""back\\slash": 1"#))
}
