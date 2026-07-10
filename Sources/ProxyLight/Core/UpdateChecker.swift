import Foundation

enum UpdateError: LocalizedError {
	case badStatus(Int)
	case responseTooLarge

	var errorDescription: String? {
		switch self {
		case .badStatus(let code): "GitHub returned HTTP \(code)."
		case .responseTooLarge: "Release info was unexpectedly large."
		}
	}
}

// Thin network wrapper (same pattern as SystemProxyManager/CATrustManager):
// fetches the latest GitHub release and defers to UpdateCheck for the logic.
struct UpdateChecker {
	private static let latestReleaseURL = URL(string: "https://api.github.com/repos/stuartshields/ProxyLight/releases/latest")!
	private static let maxResponseBytes = 1 << 20

	// Bypasses proxy settings: while ProxyLight is running, the system proxy
	// IS this app, and the update check must not depend on our own listener.
	static let session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.connectionProxyDictionary = [:]
		return URLSession(configuration: config)
	}()

	func checkForUpdate(currentVersion: String) async throws -> AvailableUpdate? {
		var request = URLRequest(url: Self.latestReleaseURL)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		let (data, response) = try await Self.session.data(for: request)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw UpdateError.badStatus(http.statusCode)
		}
		guard data.count <= Self.maxResponseBytes else { throw UpdateError.responseTooLarge }
		return try UpdateCheck.availableUpdate(fromReleaseJSON: data, currentVersion: currentVersion)
	}
}

struct AvailableUpdate: Equatable {
	var version: String
	var downloadURL: URL
}

// Pure release-check logic (no I/O) so it stays unit-testable; the network
// fetch lives in UpdateChecker below.
enum UpdateCheck {
	// Dot-separated numeric comparison. A non-numeric tail in a component
	// ("0-dev") counts as its numeric prefix, so a "0.0.0-dev" fallback build
	// sees every release as newer. Missing components compare as zero.
	static func isNewer(_ remote: String, than current: String) -> Bool {
		let r = numericComponents(of: remote)
		let c = numericComponents(of: current)
		for i in 0..<max(r.count, c.count) {
			let rv = i < r.count ? r[i] : 0
			let cv = i < c.count ? c[i] : 0
			if rv != cv { return rv > cv }
		}
		return false
	}

	private static func numericComponents(of version: String) -> [Int] {
		version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
	}

	private struct Release: Decodable {
		struct Asset: Decodable {
			let name: String
			let browserDownloadURL: URL

			private enum CodingKeys: String, CodingKey {
				case name
				case browserDownloadURL = "browser_download_url"
			}
		}

		let tagName: String
		let assets: [Asset]

		private enum CodingKeys: String, CodingKey {
			case tagName = "tag_name"
			case assets
		}
	}

	// Decodes a GitHub /releases/latest response. Returns nil when the release
	// isn't newer than currentVersion or ships no zip asset to download.
	static func availableUpdate(fromReleaseJSON data: Data, currentVersion: String) throws -> AvailableUpdate? {
		let release = try JSONDecoder().decode(Release.self, from: data)
		let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
		guard isNewer(version, than: currentVersion) else { return nil }
		guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else { return nil }
		return AvailableUpdate(version: version, downloadURL: asset.browserDownloadURL)
	}
}
