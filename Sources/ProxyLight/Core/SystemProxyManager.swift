import Foundation

protocol CommandRunner {
	func run(_ launchPath: String, _ args: [String]) throws -> String
}

struct ProcessRunner: CommandRunner {
	func run(_ launchPath: String, _ args: [String]) throws -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: launchPath)
		process.arguments = args
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		process.standardOutput = stdoutPipe
		process.standardError = stderrPipe
		try process.run()
		let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
		let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw CommandError.nonZeroExit(
				command: ([launchPath] + args).joined(separator: " "),
				status: process.terminationStatus,
				stderr: String(decoding: stderrData, as: UTF8.self)
			)
		}
		return String(decoding: stdoutData, as: UTF8.self)
	}
}

enum CommandError: Error {
	case nonZeroExit(command: String, status: Int32, stderr: String)
}

struct ProxyState: Codable, Equatable {
	var webEnabled: Bool
	var webHost: String
	var webPort: Int
	var secureEnabled: Bool
	var secureHost: String
	var securePort: Int
	var autoEnabled: Bool
	var autoURL: String

	init(webEnabled: Bool, webHost: String, webPort: Int,
		secureEnabled: Bool, secureHost: String, securePort: Int,
		autoEnabled: Bool = false, autoURL: String = "") {
		self.webEnabled = webEnabled
		self.webHost = webHost
		self.webPort = webPort
		self.secureEnabled = secureEnabled
		self.secureHost = secureHost
		self.securePort = securePort
		self.autoEnabled = autoEnabled
		self.autoURL = autoURL
	}

	// Custom decode so restore points written before PAC mode still load: the
	// missing auto fields default to "off", which is correct — pre-PAC
	// ProxyLight never enabled the system autoproxy. (Same pattern as
	// Mapping.mode.)
	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		webEnabled = try c.decode(Bool.self, forKey: .webEnabled)
		webHost = try c.decode(String.self, forKey: .webHost)
		webPort = try c.decode(Int.self, forKey: .webPort)
		secureEnabled = try c.decode(Bool.self, forKey: .secureEnabled)
		secureHost = try c.decode(String.self, forKey: .secureHost)
		securePort = try c.decode(Int.self, forKey: .securePort)
		autoEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEnabled) ?? false
		autoURL = try c.decodeIfPresent(String.self, forKey: .autoURL) ?? ""
	}

	// A ProxyLight session that quit or crashed without restoring can leave the
	// system proxy pointing at our own loopback listener. When we snapshot the
	// "previous" state on start, such a self-reference must NOT be recorded as
	// the restore target — restoring it would re-point the system at a dead
	// proxy once we stop, breaking all traffic. Return a copy with any
	// loopback:selfPort entry marked disabled so restore cleanly turns it off.
	func discardingLoopbackSelfReference(port selfPort: Int) -> ProxyState {
		let loopback: Set<String> = ["127.0.0.1", "localhost", "::1"]
		var s = self
		if s.webEnabled, loopback.contains(s.webHost.lowercased()), s.webPort == selfPort {
			s.webEnabled = false
		}
		if s.secureEnabled, loopback.contains(s.secureHost.lowercased()), s.securePort == selfPort {
			s.secureEnabled = false
		}
		if s.autoEnabled,
			let comps = URLComponents(string: s.autoURL),
			let host = comps.host, loopback.contains(host.lowercased()),
			comps.port == selfPort {
			s.autoEnabled = false
		}
		return s
	}
}

enum SystemProxyError: Error { case noActiveService }

struct SystemProxyManager {
	private let networksetup = "/usr/sbin/networksetup"
	private let runner: CommandRunner

	init(runner: CommandRunner = ProcessRunner()) {
		self.runner = runner
	}

	func activeNetworkService() throws -> String {
		// List services in hardware-port order; return the first that has an IP.
		let order = try runner.run(networksetup, ["-listnetworkserviceorder"])
		let services = Self.parseServiceOrder(order)
		for service in services {
			let info = try runner.run(networksetup, ["-getinfo", service])
			if info.contains("IP address:"),
				let line = info.split(separator: "\n").first(where: { $0.hasPrefix("IP address:") }),
				!line.contains("none") {
				return service
			}
		}
		guard let first = services.first else { throw SystemProxyError.noActiveService }
		return first
	}

	func snapshot(service: String) throws -> ProxyState {
		let web = Self.parseProxy(try runner.run(networksetup, ["-getwebproxy", service]))
		let secure = Self.parseProxy(try runner.run(networksetup, ["-getsecurewebproxy", service]))
		let auto = Self.parseAutoProxy(try runner.run(networksetup, ["-getautoproxyurl", service]))
		return ProxyState(
			webEnabled: web.enabled, webHost: web.host, webPort: web.port,
			secureEnabled: secure.enabled, secureHost: secure.host, securePort: secure.port,
			autoEnabled: auto.enabled, autoURL: auto.url
		)
	}

	func apply(pacURL: String, service: String) throws {
		_ = try runner.run(networksetup, ["-setautoproxyurl", service, pacURL])
		_ = try runner.run(networksetup, ["-setautoproxystate", service, "on"])
		// ProxyLight owns proxy policy while running: a stale global-proxy
		// entry (e.g. left by a crashed pre-PAC version) must not fight the
		// PAC. The prior values are in the snapshot and come back on restore.
		_ = try runner.run(networksetup, ["-setwebproxystate", service, "off"])
		_ = try runner.run(networksetup, ["-setsecurewebproxystate", service, "off"])
	}

	// Cache buster: macOS caches the PAC by URL, so mapping edits re-apply the
	// URL with a bumped ?v= to force a re-fetch.
	func refreshAutoProxyURL(_ url: String, service: String) throws {
		_ = try runner.run(networksetup, ["-setautoproxyurl", service, url])
	}

	func restore(_ state: ProxyState, service: String) throws {
		if state.webEnabled {
			_ = try runner.run(networksetup, ["-setwebproxy", service, state.webHost, String(state.webPort)])
			_ = try runner.run(networksetup, ["-setwebproxystate", service, "on"])
		} else {
			_ = try runner.run(networksetup, ["-setwebproxystate", service, "off"])
		}
		if state.secureEnabled {
			_ = try runner.run(networksetup, ["-setsecurewebproxy", service, state.secureHost, String(state.securePort)])
			_ = try runner.run(networksetup, ["-setsecurewebproxystate", service, "on"])
		} else {
			_ = try runner.run(networksetup, ["-setsecurewebproxystate", service, "off"])
		}
		if state.autoEnabled {
			_ = try runner.run(networksetup, ["-setautoproxyurl", service, state.autoURL])
			_ = try runner.run(networksetup, ["-setautoproxystate", service, "on"])
		} else {
			_ = try runner.run(networksetup, ["-setautoproxystate", service, "off"])
		}
	}

	private static func parseServiceOrder(_ output: String) -> [String] {
		output.split(separator: "\n")
			.filter { $0.hasPrefix("(") && $0.contains(")") && !$0.contains("Hardware Port") }
			.compactMap { line in
				guard let close = line.firstIndex(of: ")") else { return nil }
				return line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
			}
			.filter { !$0.isEmpty }
	}

	private static func parseProxy(_ output: String) -> (enabled: Bool, host: String, port: Int) {
		var enabled = false
		var host = ""
		var port = 0
		for line in output.split(separator: "\n") {
			let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			guard parts.count == 2 else { continue }
			switch parts[0] {
			case "Enabled": enabled = parts[1] == "Yes"
			case "Server": host = parts[1]
			case "Port": port = Int(parts[1]) ?? 0
			default: break
			}
		}
		return (enabled, host, port)
	}

	// `-getautoproxyurl` output:
	//   URL: http://corp.example.com/proxy.pac
	//   Enabled: Yes
	// maxSplits: 1 keeps the URL's own colons intact.
	private static func parseAutoProxy(_ output: String) -> (enabled: Bool, url: String) {
		var enabled = false
		var url = ""
		for line in output.split(separator: "\n") {
			let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			guard parts.count == 2 else { continue }
			switch parts[0] {
			case "Enabled": enabled = parts[1] == "Yes"
			case "URL": url = parts[1] == "(null)" ? "" : parts[1]
			default: break
			}
		}
		return (enabled, url)
	}
}
