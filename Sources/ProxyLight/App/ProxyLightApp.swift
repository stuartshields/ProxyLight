import SwiftUI

@main
struct ProxyLightApp: App {
	@StateObject private var state = AppState()
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

	var body: some Scene {
		MenuBarExtra {
			MenuContent(state: state)
		} label: {
			Image(systemName: state.isRunning ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
		}
		Window("Edit Mappings", id: "mappings") {
			MappingsView(state: state)
		}
		.windowResizability(.contentSize)
		Settings {
			SettingsView(state: state)
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.setActivationPolicy(.accessory)
	}
}
