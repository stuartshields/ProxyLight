import SwiftUI

// App-level settings: startup, proxy port, certificate authority.
// Mapping management lives in MappingsView ("Edit Mappings" window).
struct SettingsView: View {
	@ObservedObject var state: AppState
	@State private var showCertificate = false

	var body: some View {
		Form {
			Section {
				Toggle("Start ProxyLight at login", isOn: Binding(
					get: { state.launchAtLogin },
					set: { state.setLaunchAtLogin($0) }
				))
				if !state.launchAtLoginStatus.isEmpty {
					Text(state.launchAtLoginStatus)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Startup")
			} footer: {
				Text("When on, ProxyLight launches at login and turns the proxy on automatically.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Section("Proxy") {
				LabeledContent("Listen port") {
					TextField("Port", value: $state.config.listenPort, format: .number.grouping(.never))
						.multilineTextAlignment(.trailing)
						.frame(width: 80)
						.onSubmit { state.save() }
				}
			}

			Section("Certificate Authority") {
				Text("Trust the ProxyLight certificate so your browser accepts intercepted HTTPS mappings (your user account).")
					.font(.callout)
					.foregroundStyle(.secondary)
				Label(state.caTrusted
					? "Certificate is trusted for your user account."
					: "Certificate isn't trusted yet.",
					systemImage: state.caTrusted ? "checkmark.seal.fill" : "xmark.seal")
					.foregroundStyle(state.caTrusted ? Color.green : Color.secondary)
				Button("Trust Certificate…") { state.trustCA() }
				if !state.trustStatus.isEmpty {
					Text(state.trustStatus)
						.font(.callout)
				}
				DisclosureGroup("Certificate details", isExpanded: $showCertificate) {
					ScrollView {
						Text(state.rootCertificatePEM)
							.font(.system(.caption2, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(height: 120)
				}
			}
		}
		.formStyle(.grouped)
		.frame(width: 580, height: 440)
	}
}
