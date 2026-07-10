import SwiftUI

struct MenuContent: View {
	@ObservedObject var state: AppState
	@Environment(\.openSettings) private var openSettings
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		Button(state.isRunning ? "Turn Proxy Off" : "Turn Proxy On") { state.toggle() }
		Text(state.statusMessage)
		if !state.caAvailable {
			Text("HTTPS mappings inactive — certificate authority unavailable")
				.foregroundStyle(.red)
		}
		Divider()
		ForEach($state.config.mappings) { $mapping in
			Toggle(mapping.from, isOn: $mapping.enabled)
				.onChange(of: mapping.enabled) { _, _ in state.save() }
		}
		Divider()
		Button("Edit Mappings…") {
			openWindow(id: "mappings")
			// Accessory apps (LSUIElement) don't become frontmost on their own,
			// so windows would otherwise open/stay behind other apps.
			NSApp.activate(ignoringOtherApps: true)
		}
		Button("Settings…") {
			openSettings()
			NSApp.activate(ignoringOtherApps: true)
		}
		Button("Quit") { NSApplication.shared.terminate(nil) }
	}
}
