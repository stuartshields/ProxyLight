import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Mappings decoded from an import file, staged until the user picks which to
// keep. Identifiable so it can drive a sheet(item:) presentation.
struct PendingImport: Identifiable {
	let id = UUID()
	var mappings: [Mapping]
}

@MainActor
final class AppState: ObservableObject {
	@Published var config: AppConfig
	@Published var isRunning = false
	@Published var statusMessage = "Stopped"
	@Published var caAvailable: Bool
	// Live keychain state: whether the CA root has user-domain trust settings.
	// Refreshed at launch and after trusting, so it survives app replacement
	// and reflects trust revoked in Keychain Access.
	@Published var caTrusted = false
	@Published var trustStatus: String = ""
	@Published var transferStatus: String = ""
	@Published var launchAtLogin = false
	@Published var launchAtLoginStatus: String = ""
	// A decoded import file awaiting the user's selection in the import sheet.
	@Published var pendingImport: PendingImport?

	private let store: MappingStore
	private let restoreStore: ProxyRestoreStore
	private let proxyManager: SystemProxyManager
	private var ca: CertificateAuthority?
	private var server: ProxyServer?
	private var savedProxyState: ProxyState?
	private var activeService: String?
	private var signalSources: [DispatchSourceSignal] = []
	// Live mapping set read by the proxy's engineProvider closure from NIO
	// event-loop threads. Kept in sync with config.mappings on every save().
	private let mappingsBox = MappingsBox([])
	private let loginItemManager = LoginItemManager()

	init() {
		let dir = MappingStore.defaultDirectory
		store = MappingStore(directory: dir)
		restoreStore = ProxyRestoreStore(directory: dir)
		proxyManager = SystemProxyManager()
		config = store.load()
		ca = try? CertificateAuthority(directory: dir)
		caAvailable = ca != nil
		mappingsBox.set(config.mappings)

		recoverFromUncleanExit()
		installTerminationHandlers()
		refreshLaunchAtLogin()
		refreshCATrust()
		// Honor "start at login": if we're a registered login item, come up
		// running so traffic is routed without the user clicking anything.
		if case .enabled = loginItemManager.state {
			start()
		}
	}

	// A restore point left on disk means the previous session exited without
	// cleaning up (crash, SIGKILL, force-quit), so the system proxy may still be
	// pointed at our dead listener. Restore the saved state and clear the marker
	// so the machine isn't stranded offline before the user does anything.
	private func recoverFromUncleanExit() {
		guard let point = restoreStore.load() else { return }
		try? proxyManager.restore(point.state, service: point.service)
		restoreStore.clear()
		statusMessage = "Recovered network settings from a previous session."
	}

	private func installTerminationHandlers() {
		// Clean quit (menu Quit / Cmd-Q) restores the proxy.
		NotificationCenter.default.addObserver(
			forName: NSApplication.willTerminateNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.stop() }
		}

		// Ctrl-C / kill (SIGINT/SIGTERM) — common when launched via `swift run` —
		// bypass willTerminate, so trap them and restore before exiting. The
		// DispatchSource handler runs on the main queue (not in signal context),
		// so calling into the proxy manager here is safe; the default disposition
		// is ignored so only our handler fires.
		for sig in [SIGINT, SIGTERM] {
			signal(sig, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
			source.setEventHandler { [weak self] in
				MainActor.assumeIsolated { self?.stop() }
				exit(0)
			}
			source.resume()
			signalSources.append(source)
		}
	}

	func toggle() {
		isRunning ? stop() : start()
	}

	private func start() {
		let currentConfig = config
		// Capture only the thread-safe box, not self/currentConfig, so edits made
		// while the proxy is running (toggle/add/delete/edit a mapping) take
		// effect immediately without a stop/start cycle. Port changes still need
		// a restart to rebind the listener.
		let engineProvider: @Sendable () -> MappingEngine = { [mappingsBox] in MappingEngine(mappings: mappingsBox.get()) }
		let server = ProxyServer(port: currentConfig.listenPort, engineProvider: engineProvider, ca: ca)
		do {
			activeService = nil
			savedProxyState = nil
			let boundPort = try server.start()
			self.server = server
			let service = try proxyManager.activeNetworkService()
			activeService = service
			let snapshot = try proxyManager.snapshot(service: service).discardingLoopbackSelfReference(port: boundPort)
			savedProxyState = snapshot
			// Persist the restore point BEFORE applying, so an unclean exit at any
			// point after this can still be recovered on the next launch.
			restoreStore.save(RestorePoint(service: service, state: snapshot))
			try proxyManager.apply(host: "127.0.0.1", port: boundPort, service: service)
			isRunning = true
			statusMessage = "Running on 127.0.0.1:\(boundPort)"
		} catch {
			if let service = activeService, let saved = savedProxyState {
				try? proxyManager.restore(saved, service: service)
			}
			restoreStore.clear()
			try? server.stop()
			self.server = nil
			isRunning = false
			statusMessage = "Failed: \(error.localizedDescription). Set proxy to 127.0.0.1:\(currentConfig.listenPort) manually."
		}
	}

	private func stop() {
		if let service = activeService, let saved = savedProxyState {
			try? proxyManager.restore(saved, service: service)
		}
		// Clean shutdown: drop the restore point so the next launch doesn't think
		// we exited uncleanly.
		restoreStore.clear()
		try? server?.stop()
		server = nil
		activeService = nil
		savedProxyState = nil
		isRunning = false
		statusMessage = "Stopped"
	}

	func addMapping(from: String, to: String, mode: MappingMode) {
		config.mappings.append(Mapping(from: from, to: to, enabled: true, mode: mode))
		save()
	}

	func updateMapping(id: Mapping.ID, from: String, to: String, mode: MappingMode) {
		guard let index = config.mappings.firstIndex(where: { $0.id == id }) else { return }
		config.mappings[index].from = from
		config.mappings[index].to = to
		config.mappings[index].mode = mode
		save()
	}

	func exportMappings(_ selected: [Mapping]) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "ProxyLight-mappings.json"
		panel.allowedContentTypes = [.json]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try MappingIO.encode(selected).write(to: url, options: .atomic)
			transferStatus = "Exported \(selected.count) mapping(s)."
		} catch {
			transferStatus = "Export failed: \(error.localizedDescription)"
		}
	}

	// Decodes the chosen file and stages it; the mappings window presents a
	// selection sheet for pendingImport, then calls completeImport with the
	// mappings the user accepted.
	func importMappings() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.json]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			let imported = try MappingIO.decode(Data(contentsOf: url))
			guard !imported.isEmpty else {
				transferStatus = "No mappings found in that file."
				return
			}
			pendingImport = PendingImport(mappings: imported)
		} catch {
			transferStatus = "Import failed: \(error.localizedDescription)"
		}
	}

	func completeImport(accepted: [Mapping]) {
		pendingImport = nil
		let result = MappingIO.apply(existing: config.mappings, accepted: accepted)
		config.mappings = result.mappings
		save()
		var parts: [String] = []
		if result.added > 0 { parts.append("\(result.added) added") }
		if result.replaced > 0 { parts.append("\(result.replaced) overwritten") }
		if result.unchanged > 0 { parts.append("\(result.unchanged) already present") }
		transferStatus = parts.isEmpty ? "Nothing imported." : "Imported: " + parts.joined(separator: ", ") + "."
	}

	func deleteMapping(_ id: Mapping.ID) {
		config.mappings.removeAll { $0.id == id }
		save()
	}

	func save() {
		mappingsBox.set(config.mappings)
		try? store.save(config)
	}

	var rootCertificatePEM: String { ca?.rootCertificatePEM ?? "Certificate authority unavailable" }

	func trustCA() {
		guard let ca else {
			trustStatus = "Certificate authority unavailable."
			return
		}
		do {
			try CATrustManager().trust(certificateURL: ca.rootCertificateURL)
			trustStatus = "Restart your browser to pick up the change."
		} catch {
			trustStatus = "Failed to trust certificate: \(error.localizedDescription)"
		}
		refreshCATrust()
	}

	private func refreshCATrust() {
		guard let ca else {
			caTrusted = false
			return
		}
		caTrusted = CATrustManager().isTrusted(certificateURL: ca.rootCertificateURL)
	}

	func setLaunchAtLogin(_ enabled: Bool) {
		do {
			try loginItemManager.setEnabled(enabled)
			launchAtLoginStatus = ""
		} catch {
			launchAtLoginStatus = "Couldn't update the login item: \(error.localizedDescription)"
		}
		refreshLaunchAtLogin()
	}

	// The login-item service's status is the source of truth, so the toggle
	// always reflects reality — including when macOS needs the user to approve it.
	private func refreshLaunchAtLogin() {
		switch loginItemManager.state {
		case .enabled:
			launchAtLogin = true
		case .disabled:
			launchAtLogin = false
		case .requiresApproval:
			launchAtLogin = true
			launchAtLoginStatus = "Approve ProxyLight in System Settings › General › Login Items to finish enabling this."
		}
	}
}
