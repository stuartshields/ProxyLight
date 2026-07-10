import Foundation

// Generates the PAC (proxy auto-config) JavaScript served at /proxy.pac.
// Pure (no I/O), mirroring the MappingEngine convention, so it stays fully
// unit-testable. Matching is hostname-membership only — see the 2026-07-10
// design spec: PAC over-inclusion is safe, under-inclusion breaks rewriting.
// The mapped branch deliberately has no "; DIRECT" failover: if the proxy is
// dead while a stale PAC is cached, mapped hosts must fail loudly rather than
// silently hit the real origin.
enum PACGenerator {
	static func generate(hostnames: [String], proxyPort: Int) -> String {
		let entries = hostnames
			.map { "\"\(escapeJSStringLiteral($0.lowercased()))\": 1" }
			.joined(separator: ", ")
		return """
		function FindProxyForURL(url, host) {
			var mapped = { \(entries) };
			if (mapped[host.toLowerCase()] === 1) return "PROXY 127.0.0.1:\(proxyPort)";
			return "DIRECT";
		}
		"""
	}

	private static func escapeJSStringLiteral(_ s: String) -> String {
		s.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
	}
}
