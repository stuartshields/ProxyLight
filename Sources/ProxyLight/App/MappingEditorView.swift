import SwiftUI
import ProxyLightCore

// Modal sheet for adding OR editing a URL mapping, styled to macOS conventions:
// a grouped Form for the fields and a standard bottom button bar with Cancel on
// the left and the default action on the right. Fields are validated live; the
// confirm button stays disabled until both are present and the pair is valid.
struct MappingEditorView: View {
	let title: String
	let confirmLabel: String
	let onSave: (String, String, MappingMode) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var from: String
	@State private var to: String
	@State private var mode: MappingMode

	init(title: String = "Add URL Mapping", confirmLabel: String = "Add",
		from: String = "", to: String = "", mode: MappingMode = .rewrite,
		onSave: @escaping (String, String, MappingMode) -> Void) {
		self.title = title
		self.confirmLabel = confirmLabel
		self.onSave = onSave
		_from = State(initialValue: from)
		_to = State(initialValue: to)
		_mode = State(initialValue: mode)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(title)
				.font(.headline)
				.padding([.top, .horizontal], 20)

			Form {
				Section {
					TextField("From", text: $from, prompt: Text(verbatim: "https://local.dev/path/*"))
					TextField("To", text: $to, prompt: Text(verbatim: "https://remote.example/path/*"))
				} footer: {
					if let error = visibleError {
						Label(error.message, systemImage: "exclamationmark.triangle.fill")
							.foregroundStyle(.red)
							.font(.callout)
					} else {
						Text("Use a trailing \u{2009}*\u{2009} to map everything under a path prefix.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Section {
					Picker("When matched", selection: $mode) {
						Text("Always rewrite to remote").tag(MappingMode.rewrite)
						Text("Serve local, fall back on 404").tag(MappingMode.fallbackOnNotFound)
					}
				} footer: {
					Text(mode == .fallbackOnNotFound
						? "Served from the local origin; a 404 (or an error/non-asset response, e.g. an S3 'not found' body) is fetched from the remote target instead. GET/HEAD only."
						: "Matching requests always go to the remote target.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.formStyle(.grouped)

			Divider()

			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button(confirmLabel) {
					onSave(from, to, mode)
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
				.disabled(!canSave)
			}
			.padding(20)
		}
		.frame(width: 460)
	}

	// Surface a validation error only once the user has typed, so the sheet
	// doesn't open pre-flagged.
	private var visibleError: MappingValidationError? {
		guard !from.isEmpty || !to.isEmpty else { return nil }
		return validateMapping(from: from, to: to)
	}

	private var canSave: Bool {
		!from.isEmpty && !to.isEmpty && validateMapping(from: from, to: to) == nil
	}
}
