import Foundation
import ServiceManagement

// Whether ProxyLight is registered to launch at login. The service's own status
// is the source of truth — there is no separately-persisted flag to drift out of
// sync with what macOS actually does.
enum LoginItemState {
	case enabled          // registered and active
	case disabled         // not registered
	case requiresApproval // registered, but the user must enable it in System Settings
}

// Thin wrapper over SMAppService.mainApp so AppState never touches
// ServiceManagement directly (mirrors CATrustManager / SystemProxyManager).
struct LoginItemManager {
	var state: LoginItemState {
		switch SMAppService.mainApp.status {
		case .enabled: return .enabled
		case .requiresApproval: return .requiresApproval
		case .notRegistered, .notFound: return .disabled
		@unknown default: return .disabled
		}
	}

	// Throws when registration isn't possible — e.g. running an unbundled build
	// via `swift run`, or an unsigned copy. Callers surface the error and fall
	// back to reading `state` so the UI reflects reality.
	func setEnabled(_ enabled: Bool) throws {
		if enabled {
			try SMAppService.mainApp.register()
		} else {
			try SMAppService.mainApp.unregister()
		}
	}
}
