import Foundation

struct RewriteResult: Equatable {
	var scheme: String
	var host: String
	var port: Int
	var uri: String
	// The remote target the request maps to. In .rewrite mode the proxy forwards
	// here unconditionally; in .fallbackOnNotFound mode it uses this only if the
	// local origin returns 404. Defaults to .rewrite so existing construction
	// sites (and pre-mode tests) are unaffected.
	var mode: MappingMode = .rewrite
}

struct MappingEngine {
	private struct Parsed {
		let scheme: String
		let host: String
		let port: Int
		let pathPrefix: String
		let hasWildcard: Bool
	}

	private struct Rule {
		let from: Parsed
		let to: Parsed
		let mode: MappingMode
	}

	struct HostKey: Hashable { let scheme: String; let host: String; let port: Int }

	private let rules: [Rule]
	private let hostsInScope: Set<HostKey>

	init(mappings: [Mapping]) {
		rules = mappings.compactMap { mapping in
			guard mapping.enabled,
				let from = Self.parse(mapping.from),
				let to = Self.parse(mapping.to),
				from.hasWildcard == to.hasWildcard
			else { return nil }
			return Rule(from: from, to: to, mode: mapping.mode)
		}
		hostsInScope = Set(rules.map { HostKey(scheme: $0.from.scheme, host: $0.from.host, port: $0.from.port) })
	}

	// Host-only membership check, used by CONNECT dispatch before the inner
	// request path is known (a CONNECT only carries host:port, no path).
	func matchesHost(scheme: String, host: String, port: Int) -> Bool {
		hostsInScope.contains(HostKey(scheme: scheme, host: host.lowercased(), port: port))
	}

	func rewrite(scheme: String, host: String, port: Int, uri: String) -> RewriteResult? {
		let host = host.lowercased()
		let (path, query) = Self.splitQuery(uri)
		var best: (rule: Rule, remainder: String, prefixLen: Int)?

		for rule in rules {
			let f = rule.from
			guard f.scheme == scheme, f.host == host, f.port == port else { continue }

			let remainder: String
			if f.hasWildcard {
				guard path.hasPrefix(f.pathPrefix) else { continue }
				remainder = String(path.dropFirst(f.pathPrefix.count))
			} else {
				guard path == f.pathPrefix else { continue }
				remainder = ""
			}

			if best == nil || f.pathPrefix.count > best!.prefixLen {
				best = (rule, remainder, f.pathPrefix.count)
			}
		}

		guard let match = best else { return nil }
		let t = match.rule.to
		var newPath = t.pathPrefix + match.remainder
		if !query.isEmpty { newPath += "?" + query }
		return RewriteResult(scheme: t.scheme, host: t.host, port: t.port, uri: newPath, mode: match.rule.mode)
	}

	private static func splitQuery(_ uri: String) -> (path: String, query: String) {
		guard let idx = uri.firstIndex(of: "?") else { return (uri, "") }
		return (String(uri[uri.startIndex..<idx]), String(uri[uri.index(after: idx)...]))
	}

	private static func parse(_ pattern: String) -> Parsed? {
		guard let comps = URLComponents(string: pattern),
			let scheme = comps.scheme?.lowercased(),
			scheme == "http" || scheme == "https",
			let host = comps.host?.lowercased()
		else { return nil }

		let port = comps.port ?? (scheme == "https" ? 443 : 80)
		let rawPath = comps.path.isEmpty ? "/" : comps.path
		let hasWildcard = rawPath.hasSuffix("*")
		let pathPrefix = hasWildcard ? String(rawPath.dropLast()) : rawPath
		return Parsed(scheme: scheme, host: host, port: port, pathPrefix: pathPrefix, hasWildcard: hasWildcard)
	}
}
