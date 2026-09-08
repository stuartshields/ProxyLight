import Testing
import Foundation
@testable import ProxyLight

@Test func processRunnerThrowsOnNonZeroExit() {
	let runner = ProcessRunner()
	#expect(throws: (any Error).self) {
		_ = try runner.run("/usr/bin/false", [])
	}
}

@Test func processRunnerReturnsStdoutOnSuccess() throws {
	let runner = ProcessRunner()
	let out = try runner.run("/bin/echo", ["hello"])
	#expect(out.contains("hello"))
}

final class FakeRunner: CommandRunner {
	var responses: [String]
	var calls: [[String]] = []
	var launchPaths: [String] = []
	var errorToThrow: Error?
	init(_ responses: [String]) { self.responses = responses }
	func run(_ launchPath: String, _ args: [String]) throws -> String {
		if let errorToThrow { throw errorToThrow }
		launchPaths.append(launchPath)
		calls.append(args)
		return responses.isEmpty ? "" : responses.removeFirst()
	}
}

@Test func snapshotParsesNetworksetupOutput() throws {
	let webOut = "Enabled: Yes\nServer: 127.0.0.1\nPort: 9876\nAuthenticated Proxy Enabled: 0\n"
	let secureOut = "Enabled: No\nServer:\nPort: 0\nAuthenticated Proxy Enabled: 0\n"
	let autoOut = "URL: (null)\nEnabled: No\n"
	let runner = FakeRunner([webOut, secureOut, autoOut])
	let mgr = SystemProxyManager(runner: runner)
	let state = try mgr.snapshot(service: "Wi-Fi")
	#expect(state.webEnabled == true)
	#expect(state.webHost == "127.0.0.1")
	#expect(state.webPort == 9876)
	#expect(state.secureEnabled == false)
}

@Test func restoreReenablesPreviouslyEnabledProxy() throws {
	let runner = FakeRunner([])
	let mgr = SystemProxyManager(runner: runner)
	let state = ProxyState(webEnabled: true, webHost: "10.0.0.1", webPort: 3128,
		secureEnabled: true, secureHost: "10.0.0.2", securePort: 3129)
	try mgr.restore(state, service: "Wi-Fi")
	#expect(runner.calls.contains(["-setwebproxy", "Wi-Fi", "10.0.0.1", "3128"]))
	#expect(runner.calls.contains(["-setwebproxystate", "Wi-Fi", "on"]))
	#expect(runner.calls.contains(["-setsecurewebproxy", "Wi-Fi", "10.0.0.2", "3129"]))
	#expect(runner.calls.contains(["-setsecurewebproxystate", "Wi-Fi", "on"]))
}

@Test func restoreTurnsOffPreviouslyDisabledProxy() throws {
	let runner = FakeRunner([])
	let mgr = SystemProxyManager(runner: runner)
	let state = ProxyState(webEnabled: false, webHost: "", webPort: 0,
		secureEnabled: false, secureHost: "", securePort: 0)
	try mgr.restore(state, service: "Wi-Fi")
	#expect(runner.calls.contains(["-setwebproxystate", "Wi-Fi", "off"]))
	#expect(runner.calls.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]))
	// Must NOT re-apply host/port when the prior state was disabled.
	#expect(!runner.calls.contains { $0.first == "-setwebproxy" })
	#expect(!runner.calls.contains { $0.first == "-setsecurewebproxy" })
}

@Test func applyPACSetsAutoProxyAndDisablesGlobalProxies() throws {
	let runner = FakeRunner([])
	let mgr = SystemProxyManager(runner: runner)
	try mgr.apply(pacURL: "http://127.0.0.1:9876/proxy.pac?v=1", service: "Wi-Fi")
	#expect(runner.calls.contains(["-setautoproxyurl", "Wi-Fi", "http://127.0.0.1:9876/proxy.pac?v=1"]))
	#expect(runner.calls.contains(["-setautoproxystate", "Wi-Fi", "on"]))
	#expect(runner.calls.contains(["-setwebproxystate", "Wi-Fi", "off"]))
	#expect(runner.calls.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]))
	// PAC mode must NOT configure the global proxies' host/port.
	#expect(!runner.calls.contains { $0.first == "-setwebproxy" })
	#expect(!runner.calls.contains { $0.first == "-setsecurewebproxy" })
}

@Test func refreshAutoProxyURLIssuesOnlyTheURLCommand() throws {
	let runner = FakeRunner([])
	let mgr = SystemProxyManager(runner: runner)
	try mgr.refreshAutoProxyURL("http://127.0.0.1:9876/proxy.pac?v=2", service: "Wi-Fi")
	#expect(runner.calls == [["-setautoproxyurl", "Wi-Fi", "http://127.0.0.1:9876/proxy.pac?v=2"]])
}

@Test func snapshotParsesAutoProxyOutput() throws {
	let webOut = "Enabled: No\nServer:\nPort: 0\n"
	let secureOut = "Enabled: No\nServer:\nPort: 0\n"
	let autoOut = "URL: http://corp.example.com/proxy.pac\nEnabled: Yes\n"
	let runner = FakeRunner([webOut, secureOut, autoOut])
	let mgr = SystemProxyManager(runner: runner)
	let state = try mgr.snapshot(service: "Wi-Fi")
	#expect(state.autoEnabled == true)
	#expect(state.autoURL == "http://corp.example.com/proxy.pac")
	#expect(runner.calls.contains(["-getautoproxyurl", "Wi-Fi"]))
}

@Test func restoreReenablesPreviouslyEnabledAutoProxy() throws {
	let runner = FakeRunner([])
	let mgr = SystemProxyManager(runner: runner)
	let state = ProxyState(webEnabled: false, webHost: "", webPort: 0,
		secureEnabled: false, secureHost: "", securePort: 0,
		autoEnabled: true, autoURL: "http://corp.example.com/proxy.pac")
	try mgr.restore(state, service: "Wi-Fi")
	#expect(runner.calls.contains(["-setautoproxyurl", "Wi-Fi", "http://corp.example.com/proxy.pac"]))
	#expect(runner.calls.contains(["-setautoproxystate", "Wi-Fi", "on"]))
}

@Test func restoreTurnsOffPreviouslyDisabledAutoProxy() throws {
	let runner = FakeRunner([])
	let mgr = SystemProxyManager(runner: runner)
	let state = ProxyState(webEnabled: false, webHost: "", webPort: 0,
		secureEnabled: false, secureHost: "", securePort: 0)
	try mgr.restore(state, service: "Wi-Fi")
	#expect(runner.calls.contains(["-setautoproxystate", "Wi-Fi", "off"]))
	#expect(!runner.calls.contains { $0.first == "-setautoproxyurl" })
}

@Test func proxyRestoreStoreRoundTripsAndClears() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: dir) }

	let store = ProxyRestoreStore(directory: dir)
	#expect(store.load() == nil)

	let point = RestorePoint(service: "Wi-Fi", state: ProxyState(
		webEnabled: false, webHost: "", webPort: 0,
		secureEnabled: true, secureHost: "10.0.0.1", securePort: 3128))
	store.save(point)
	#expect(store.load() == point)

	store.clear()
	#expect(store.load() == nil)
}

@Test func discardsSelfReferencingProxyStateSoRestoreTurnsItOff() {
	// A stale ProxyLight setting left by a prior session: system proxy points at
	// our own loopback listener. Snapshotting this as the restore target would
	// make "off" re-point the system at a dead proxy — breaking all traffic.
	let selfRef = ProxyState(webEnabled: true, webHost: "127.0.0.1", webPort: 9876,
		secureEnabled: true, secureHost: "127.0.0.1", securePort: 9876)
	let sanitized = selfRef.discardingLoopbackSelfReference(port: 9876)
	#expect(sanitized.webEnabled == false)
	#expect(sanitized.secureEnabled == false)
}

@Test func discardsLocalhostSelfReference() {
	let selfRef = ProxyState(webEnabled: true, webHost: "localhost", webPort: 9876,
		secureEnabled: false, secureHost: "", securePort: 0)
	#expect(selfRef.discardingLoopbackSelfReference(port: 9876).webEnabled == false)
}

@Test func preservesRealPreviousProxy() {
	// A genuine upstream proxy the user had configured must be kept intact so it
	// is faithfully restored when ProxyLight stops.
	let real = ProxyState(webEnabled: true, webHost: "proxy.corp.example", webPort: 3128,
		secureEnabled: true, secureHost: "proxy.corp.example", securePort: 3128)
	#expect(real.discardingLoopbackSelfReference(port: 9876) == real)
}

@Test func preservesLoopbackProxyOnDifferentPort() {
	// A loopback proxy on a different port isn't us — keep it.
	let other = ProxyState(webEnabled: true, webHost: "127.0.0.1", webPort: 8080,
		secureEnabled: false, secureHost: "", securePort: 0)
	#expect(other.discardingLoopbackSelfReference(port: 9876) == other)
}

@Test func catrustBuildsCorrectSecurityCommand() {
	let path = "/Users/x/Library/Application Support/ProxyLight/ca.cert.pem"
	let loginKeychain = "/Users/x/Library/Keychains/login.keychain-db"
	let command = CATrustManager.trustCommand(certificatePath: path, loginKeychainPath: loginKeychain)
	// Runs `security` directly (no shell, no osascript): trust is set in the
	// USER domain — no `-d`, no System keychain, no admin — because admin-domain
	// trust needs an interactive auth session the app process lacks.
	#expect(command.launchPath == "/usr/bin/security")
	#expect(command.args == ["add-trusted-cert", "-r", "trustRoot", "-k", loginKeychain, path])
	// Must NOT use the admin/System-keychain domain.
	#expect(!command.args.contains("-d"))
	#expect(!command.args.contains("/Library/Keychains/System.keychain"))
}

@Test func catrustPassesPathVerbatimWithoutShell() {
	// The command is argv-based (ProcessRunner → security, no /bin/sh), so a
	// path with spaces or shell metacharacters is passed as one exact argument
	// and can never be word-split or shell-evaluated — no quoting needed.
	let trickyPath = "/tmp/$(id) dir/ca.pem"
	let loginKeychain = "/Users/x/Library/Keychains/login.keychain-db"
	let command = CATrustManager.trustCommand(certificatePath: trickyPath, loginKeychainPath: loginKeychain)
	#expect(command.args.last == trickyPath)
	#expect(command.args.contains(trickyPath))
}

@Test func catrustInvokesRunnerAndThrowsOnFailure() throws {
	let path = "/Users/x/Library/Application Support/ProxyLight/ca.cert.pem"
	let certificateURL = URL(fileURLWithPath: path)

	let successRunner = FakeRunner([""])
	let manager = CATrustManager(runner: successRunner)
	try manager.trust(certificateURL: certificateURL)
	#expect(successRunner.launchPaths == ["/usr/bin/security"])
	#expect(successRunner.calls.first?.first == "add-trusted-cert")
	#expect(successRunner.calls.first?.contains(path) == true)

	let failingRunner = FakeRunner([])
	failingRunner.errorToThrow = CommandError.nonZeroExit(command: "security", status: 1, stderr: "denied")
	let failingManager = CATrustManager(runner: failingRunner)
	#expect(throws: CATrustError.self) {
		try failingManager.trust(certificateURL: certificateURL)
	}
}

@Test func proxyStateDecodesLegacyJSONWithoutAutoFields() throws {
	// Restore points written by pre-PAC versions lack the auto fields.
	let json = #"{"webEnabled":true,"webHost":"127.0.0.1","webPort":9876,"secureEnabled":false,"secureHost":"","securePort":0}"#
	let state = try JSONDecoder().decode(ProxyState.self, from: Data(json.utf8))
	#expect(state.autoEnabled == false)
	#expect(state.autoURL == "")
	#expect(state.webEnabled == true)
}

@Test func proxyStateRoundTripsAutoFields() throws {
	let state = ProxyState(webEnabled: false, webHost: "", webPort: 0,
		secureEnabled: false, secureHost: "", securePort: 0,
		autoEnabled: true, autoURL: "http://example.com/proxy.pac")
	let decoded = try JSONDecoder().decode(ProxyState.self, from: JSONEncoder().encode(state))
	#expect(decoded == state)
}

@Test func discardsLoopbackSelfReferencingAutoProxyURL() {
	let state = ProxyState(webEnabled: false, webHost: "", webPort: 0,
		secureEnabled: false, secureHost: "", securePort: 0,
		autoEnabled: true, autoURL: "http://127.0.0.1:9876/proxy.pac?v=3")
	let cleaned = state.discardingLoopbackSelfReference(port: 9876)
	#expect(cleaned.autoEnabled == false)
}

@Test func keepsForeignAutoProxyURL() {
	let state = ProxyState(webEnabled: false, webHost: "", webPort: 0,
		secureEnabled: false, secureHost: "", securePort: 0,
		autoEnabled: true, autoURL: "http://corp.example.com/proxy.pac")
	let cleaned = state.discardingLoopbackSelfReference(port: 9876)
	#expect(cleaned.autoEnabled == true)
	#expect(cleaned.autoURL == "http://corp.example.com/proxy.pac")
}
