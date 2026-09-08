import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ProxyLightCore

// Mappings decoded from an import file, staged until the user picks which to
// keep. Identifiable so it can drive a sheet(item:) presentation.
struct PendingImport: Identifiable {
	let id = UUID()
	var mappings: [Mapping]
}

@MainActor
final class AppState: ObservableObject {
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
	// Set when a manual check finds a newer GitHub release; drives the
	// "Download x.x.x" buttons in Settings and the menu.
	@Published var availableUpdate: AvailableUpdate?
	@Published var updateStatus = ""
	@Published var isCheckingForUpdates = false
	@Published var isInstallingUpdate = false

	// Version the packaged app reports. `swift run` has no Info.plist, so dev
	// builds fall back to a version every release beats.
	static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"

	private let orchestrator: ProxyOrchestrator
	private let restoreStore: ProxyRestoreStore
	private let proxyManager: SystemProxyManager
	private var savedProxyState: ProxyState?
	private var activeService: String?
	private var signalSources: [DispatchSourceSignal] = []
	private let loginItemManager = LoginItemManager()
	private var updateCheckTimer: Timer?

	// Quiet checks keep the update discoverable without the user opening
	// Settings: at launch (delayed so a login-time start has network), then daily.
	private static let launchUpdateCheckDelay: Duration = .seconds(10)
	private static let backgroundUpdateCheckInterval: TimeInterval = 24 * 60 * 60

	// Computed (not @Published) because the source of truth lives in
	// orchestrator; objectWillChange is sent manually so SwiftUI bindings
	// ($state.config.mappings, $state.config.listenPort) still redraw on edit.
	var config: AppConfig {
		get { orchestrator.config }
		set {
			objectWillChange.send()
			orchestrator.config = newValue
		}
	}

	// Persists the current config and, if running, re-applies the PAC.
	// Views call this explicitly after a binding-driven edit (mapping toggle,
	// port field) — see the .onChange/.onSubmit call sites.
	func save() {
		orchestrator.save()
		refreshPACIfRunning()
	}

	init() {
		let dir = ProxyOrchestrator.defaultDirectory
		orchestrator = ProxyOrchestrator(directory: dir)
		restoreStore = ProxyRestoreStore(directory: dir)
		proxyManager = SystemProxyManager()
		caAvailable = orchestrator.rootCertificateURL != nil

		recoverFromUncleanExit()
		installTerminationHandlers()
		refreshLaunchAtLogin()
		refreshCATrust()
		scheduleBackgroundUpdateChecks()
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
		do {
			activeService = nil
			savedProxyState = nil
			let boundPort = try orchestrator.start()
			let service = try proxyManager.activeNetworkService()
			activeService = service
			let snapshot = try proxyManager.snapshot(service: service).discardingLoopbackSelfReference(port: boundPort)
			savedProxyState = snapshot
			// Persist the restore point BEFORE applying, so an unclean exit at any
			// point after this can still be recovered on the next launch.
			restoreStore.save(RestorePoint(service: service, state: snapshot))
			try proxyManager.apply(pacURL: orchestrator.pacURL()!, service: service)
			isRunning = true
			statusMessage = "Running on 127.0.0.1:\(boundPort) (PAC)"
		} catch {
			if let service = activeService, let saved = savedProxyState {
				try? proxyManager.restore(saved, service: service)
			}
			restoreStore.clear()
			try? orchestrator.stop()
			isRunning = false
			statusMessage = "Failed: \(error.localizedDescription). Set the Automatic Proxy Configuration URL to http://127.0.0.1:\(orchestrator.config.listenPort)/proxy.pac manually."
		}
	}

	private func stop() {
		if let service = activeService, let saved = savedProxyState {
			try? proxyManager.restore(saved, service: service)
		}
		// Clean shutdown: drop the restore point so the next launch doesn't think
		// we exited uncleanly.
		restoreStore.clear()
		try? orchestrator.stop()
		activeService = nil
		savedProxyState = nil
		isRunning = false
		statusMessage = "Stopped"
	}

	func addMapping(from: String, to: String, mode: MappingMode) {
		orchestrator.addMapping(from: from, to: to, mode: mode)
		refreshPACIfRunning()
	}

	func updateMapping(id: Mapping.ID, from: String, to: String, mode: MappingMode) {
		orchestrator.updateMapping(id: id, from: from, to: to, mode: mode)
		refreshPACIfRunning()
	}

	func exportMappings(_ selected: [Mapping]) {
		let panel = NSSavePanel()
		panel.nameFieldStringValue = "ProxyLight-mappings.json"
		panel.allowedContentTypes = [.json]
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try orchestrator.exportData(selected).write(to: url, options: .atomic)
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
			let imported = try orchestrator.decodeImportFile(Data(contentsOf: url))
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
		let result = orchestrator.completeImport(accepted: accepted)
		refreshPACIfRunning()
		var parts: [String] = []
		if result.added > 0 { parts.append("\(result.added) added") }
		if result.replaced > 0 { parts.append("\(result.replaced) overwritten") }
		if result.unchanged > 0 { parts.append("\(result.unchanged) already present") }
		transferStatus = parts.isEmpty ? "Nothing imported." : "Imported: " + parts.joined(separator: ", ") + "."
	}

	func deleteMapping(_ id: Mapping.ID) {
		orchestrator.deleteMapping(id)
		refreshPACIfRunning()
	}

	// Mapping edits change which hosts the PAC routes through the proxy, and
	// macOS caches the PAC by URL — so bump ?v= and re-apply. A networksetup
	// hiccup must not roll back the saved mapping; surface it instead.
	private func refreshPACIfRunning() {
		guard isRunning, let service = activeService, let pacURL = orchestrator.pacURL() else { return }
		do {
			try proxyManager.refreshAutoProxyURL(pacURL, service: service)
			statusMessage = "Running on 127.0.0.1:\(orchestrator.runningPort!) (PAC)"
		} catch {
			statusMessage = "Mapping saved, but the system PAC may be stale — toggle the proxy off and on."
		}
	}

	var rootCertificatePEM: String { orchestrator.rootCertificatePEM }

	func trustCA() {
		guard let rootCertificateURL = orchestrator.rootCertificateURL else {
			trustStatus = "Certificate authority unavailable."
			return
		}
		do {
			try CATrustManager().trust(certificateURL: rootCertificateURL)
			trustStatus = "Restart your browser to pick up the change."
		} catch {
			trustStatus = "Failed to trust certificate: \(error.localizedDescription)"
		}
		refreshCATrust()
	}

	private func refreshCATrust() {
		guard let rootCertificateURL = orchestrator.rootCertificateURL else {
			caTrusted = false
			return
		}
		caTrusted = CATrustManager().isTrusted(certificateURL: rootCertificateURL)
	}

	func checkForUpdates() {
		checkForUpdates(quietly: false)
	}

	// A quiet check updates availableUpdate (so the menu's update button
	// appears) but never writes status text the user didn't ask for.
	private func checkForUpdates(quietly: Bool) {
		guard !isCheckingForUpdates else { return }
		isCheckingForUpdates = true
		if !quietly { updateStatus = "" }
		Task {
			do {
				availableUpdate = try await UpdateChecker().checkForUpdate(currentVersion: Self.appVersion)
				if !quietly { updateStatus = availableUpdate == nil ? "ProxyLight is up to date." : "" }
			} catch {
				if !quietly { updateStatus = "Update check failed: \(error.localizedDescription)" }
			}
			isCheckingForUpdates = false
		}
	}

	private func scheduleBackgroundUpdateChecks() {
		Task { [weak self] in
			try? await Task.sleep(for: Self.launchUpdateCheckDelay)
			self?.checkForUpdates(quietly: true)
		}
		updateCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.backgroundUpdateCheckInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.checkForUpdates(quietly: true) }
		}
	}

	func installUpdate() {
		guard let update = availableUpdate, !isInstallingUpdate else { return }
		isInstallingUpdate = true
		Task {
			do {
				let installed = try await SelfUpdater().installUpdate(from: update.downloadURL) { [weak self] phase in
					self?.updateStatus = Self.statusText(for: phase, version: update.version)
				}
				updateStatus = "Relaunching…"
				try SelfUpdater.spawnRelauncher(appPath: installed.path)
				NSApplication.shared.terminate(nil)
			} catch SelfUpdateError.notInstalledAsApp, SelfUpdateError.unsignedHostApp {
				// Dev and unsigned builds can't verify an update, so hand the
				// zip to the browser instead of installing unverified code.
				NSWorkspace.shared.open(update.downloadURL)
				updateStatus = "This build can't self-update — opened the download in your browser."
			} catch {
				updateStatus = "Update failed: \(error.localizedDescription)"
			}
			isInstallingUpdate = false
		}
	}

	private static func statusText(for phase: UpdatePhase, version: String) -> String {
		switch phase {
		case .downloading: "Downloading \(version)…"
		case .verifying: "Verifying download…"
		case .installing: "Installing…"
		}
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
