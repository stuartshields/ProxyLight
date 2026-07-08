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
		return ProxyState(
			webEnabled: web.enabled, webHost: web.host, webPort: web.port,
			secureEnabled: secure.enabled, secureHost: secure.host, securePort: secure.port
		)
	}

	func apply(host: String, port: Int, service: String) throws {
		_ = try runner.run(networksetup, ["-setwebproxy", service, host, String(port)])
		_ = try runner.run(networksetup, ["-setsecurewebproxy", service, host, String(port)])
		_ = try runner.run(networksetup, ["-setwebproxystate", service, "on"])
		_ = try runner.run(networksetup, ["-setsecurewebproxystate", service, "on"])
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
}
