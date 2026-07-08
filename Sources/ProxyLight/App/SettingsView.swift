import SwiftUI

struct SettingsView: View {
	@ObservedObject var state: AppState
	@State private var editorTarget: EditorTarget?
	@State private var showCertificate = false

	// Drives the single add/edit sheet. `.add` starts empty; `.edit` pre-fills
	// the chosen mapping.
	private enum EditorTarget: Identifiable {
		case add
		case edit(Mapping)
		var id: String {
			switch self {
			case .add: return "add"
			case .edit(let mapping): return mapping.id.uuidString
			}
		}
	}

	var body: some View {
		Form {
			if !state.caAvailable {
				Section {
					Label("HTTPS mappings inactive — certificate authority unavailable. HTTPS traffic passes through untouched.", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
						.font(.callout)
				}
			}

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

			Section {
				if state.config.mappings.isEmpty {
					Text("No mappings yet. Add one to start rewriting URLs.")
						.foregroundStyle(.secondary)
				}
				ForEach($state.config.mappings) { $mapping in
					mappingRow($mapping)
				}
			} header: {
				Text("Mappings")
			} footer: {
				if invalidMappingCount > 0 {
					Label("\(invalidMappingCount) mapping(s) are invalid and ignored.", systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
						.font(.caption)
				}
			}

			Section {
				Button("Add Mapping…") { editorTarget = .add }
				HStack {
					Button("Import…") { state.importMappings() }
					Button("Export…") { state.exportMappings() }
						.disabled(state.config.mappings.isEmpty)
					Spacer()
				}
				if !state.transferStatus.isEmpty {
					Text(state.transferStatus)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			} footer: {
				Text("Export shares your mappings as a JSON file; Import merges another file's mappings into yours (duplicates skipped).")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			Section("Certificate Authority") {
				Text("Trust the ProxyLight certificate so your browser accepts intercepted HTTPS mappings (your user account).")
					.font(.callout)
					.foregroundStyle(.secondary)
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
		.frame(width: 580, height: 560)
		.sheet(item: $editorTarget) { target in
			switch target {
			case .add:
				MappingEditorView(title: "Add URL Mapping", confirmLabel: "Add") { from, to, mode in
					state.addMapping(from: from, to: to, mode: mode)
				}
			case .edit(let mapping):
				MappingEditorView(title: "Edit URL Mapping", confirmLabel: "Save",
					from: mapping.from, to: mapping.to, mode: mapping.mode) { from, to, mode in
					state.updateMapping(id: mapping.id, from: from, to: to, mode: mode)
				}
			}
		}
	}

	@ViewBuilder
	private func mappingRow(_ mapping: Binding<Mapping>) -> some View {
		let invalid = validateMapping(from: mapping.wrappedValue.from, to: mapping.wrappedValue.to) != nil
		HStack(spacing: 10) {
			Toggle("", isOn: mapping.enabled)
				.labelsHidden()
				.toggleStyle(.switch)
				.controlSize(.small)
				.onChange(of: mapping.wrappedValue.enabled) { _, _ in state.save() }
			VStack(alignment: .leading, spacing: 1) {
				Text(mapping.wrappedValue.from)
					.lineLimit(1)
					.truncationMode(.middle)
				Text(mapping.wrappedValue.to)
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
					.truncationMode(.middle)
			}
			Spacer(minLength: 8)
			if mapping.wrappedValue.mode == .fallbackOnNotFound {
				Text("Fallback")
					.font(.caption2)
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(Capsule().fill(Color.secondary.opacity(0.2)))
					.help("Serves the local origin; falls back to the remote target on 404.")
			}
			if invalid {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(.red)
					.help("This mapping is invalid and will be ignored.")
			}
			Button {
				editorTarget = .edit(mapping.wrappedValue)
			} label: {
				Image(systemName: "pencil")
			}
			.buttonStyle(.borderless)
			.help("Edit mapping")
			Button {
				state.deleteMapping(mapping.wrappedValue.id)
			} label: {
				Image(systemName: "trash")
			}
			.buttonStyle(.borderless)
			.help("Delete mapping")
		}
	}

	private var invalidMappingCount: Int {
		state.config.mappings.filter { validateMapping(from: $0.from, to: $0.to) != nil }.count
	}
}
