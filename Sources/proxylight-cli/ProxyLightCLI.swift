import ArgumentParser
import Foundation
import ProxyLightCore

@main
struct ProxyLightCLI: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "proxylight",
		abstract: "Local HTTP/HTTPS mapping proxy — rewrites mapped URL patterns to remote origins.",
		subcommands: [Start.self, Mapping_.self, Import.self, Export.self, CAPath.self],
		defaultSubcommand: Start.self
	)
}

func configDirectory() -> URL {
	ProxyOrchestrator.defaultDirectory
}

struct Start: ParsableCommand {
	static let configuration = CommandConfiguration(abstract: "Start the proxy and block until interrupted (Ctrl-C).")

	@Option(name: .long, help: "Override the configured listen port.")
	var port: Int?

	func run() throws {
		let orchestrator = ProxyOrchestrator(directory: configDirectory())
		if let port { orchestrator.config.listenPort = port }

		let boundPort = try orchestrator.start()
		print("Listening on 127.0.0.1:\(boundPort)")
		print("PAC URL: \(orchestrator.pacURL() ?? "unavailable")")
		print("Point your browser's automatic proxy configuration at the PAC URL above.")
		if let certURL = orchestrator.rootCertificateURL {
			print("CA certificate: \(certURL.path) — import this into your browser's trust store to intercept HTTPS.")
		} else {
			print("Warning: certificate authority unavailable — HTTPS mappings will pass through untouched.")
		}

		// The main thread blocks on the semaphore below rather than running a
		// run loop, so these must fire on a queue GCD services independently —
		// `.main` would never drain and Ctrl-C/kill would hang forever.
		let signalQueue = DispatchQueue(label: "proxylight.signals")
		let semaphore = DispatchSemaphore(value: 0)
		var sources: [DispatchSourceSignal] = []
		for sig in [SIGINT, SIGTERM] {
			signal(sig, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
			source.setEventHandler { semaphore.signal() }
			source.resume()
			sources.append(source)
		}
		semaphore.wait()
		try? orchestrator.stop()
		print("Stopped.")
	}
}

struct Mapping_: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "mapping",
		abstract: "Manage URL mappings.",
		subcommands: [Add.self, List.self, Remove.self]
	)

	struct Add: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Add a mapping.")

		@Argument(help: "Pattern to match, e.g. https://local.dev/path/*")
		var from: String

		@Argument(help: "Remote target, e.g. https://remote.example/path/*")
		var to: String

		@Flag(name: .long, help: "Serve local first, fall back to remote on 404.")
		var fallbackOnNotFound = false

		func run() throws {
			if let error = validateMapping(from: from, to: to) {
				throw ValidationError(error.message)
			}
			let orchestrator = ProxyOrchestrator(directory: configDirectory())
			orchestrator.addMapping(from: from, to: to, mode: fallbackOnNotFound ? .fallbackOnNotFound : .rewrite)
			print("Added: \(from) -> \(to)")
		}
	}

	struct List: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "List mappings.")

		func run() throws {
			let orchestrator = ProxyOrchestrator(directory: configDirectory())
			if orchestrator.config.mappings.isEmpty {
				print("No mappings.")
				return
			}
			for mapping in orchestrator.config.mappings {
				let flag = mapping.enabled ? "" : " (disabled)"
				print("\(mapping.id): \(mapping.from) -> \(mapping.to) [\(mapping.mode)]\(flag)")
			}
		}
	}

	struct Remove: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Remove a mapping by id.")

		@Argument(help: "Mapping id, as printed by `mapping list`.")
		var id: String

		func run() throws {
			guard let uuid = UUID(uuidString: id) else {
				throw ValidationError("'\(id)' isn't a valid mapping id.")
			}
			let orchestrator = ProxyOrchestrator(directory: configDirectory())
			orchestrator.deleteMapping(uuid)
			print("Removed \(id) (if it existed).")
		}
	}
}

struct Import: ParsableCommand {
	static let configuration = CommandConfiguration(abstract: "Import mappings from a JSON file, overwriting conflicts.")

	@Argument(help: "Path to a mappings JSON file.")
	var file: String

	func run() throws {
		let orchestrator = ProxyOrchestrator(directory: configDirectory())
		let data = try Data(contentsOf: URL(fileURLWithPath: file))
		let imported = try orchestrator.decodeImportFile(data)
		let result = orchestrator.completeImport(accepted: imported)
		print("Imported: \(result.added) added, \(result.replaced) overwritten, \(result.unchanged) already present.")
	}
}

struct Export: ParsableCommand {
	static let configuration = CommandConfiguration(abstract: "Export all mappings to a JSON file.")

	@Argument(help: "Path to write the mappings JSON file.")
	var file: String

	func run() throws {
		let orchestrator = ProxyOrchestrator(directory: configDirectory())
		let data = try orchestrator.exportData(orchestrator.config.mappings)
		try data.write(to: URL(fileURLWithPath: file), options: .atomic)
		print("Exported \(orchestrator.config.mappings.count) mapping(s) to \(file).")
	}
}

struct CAPath: ParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "ca-path",
		abstract: "Print the path to the generated CA certificate, for manual import into a browser's trust store."
	)

	func run() throws {
		let orchestrator = ProxyOrchestrator(directory: configDirectory())
		guard let certURL = orchestrator.rootCertificateURL else {
			throw ValidationError("Certificate authority unavailable.")
		}
		print(certURL.path)
	}
}
