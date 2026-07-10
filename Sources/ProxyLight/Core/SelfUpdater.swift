import Foundation
import Security

enum SelfUpdateError: LocalizedError {
	case notInstalledAsApp
	case unsignedHostApp
	case noAppInArchive
	case archiveTooLarge
	case verificationFailed(String)
	case extractionFailed(String)

	var errorDescription: String? {
		switch self {
		case .notInstalledAsApp: "This build isn't running from an installed app bundle."
		case .unsignedHostApp: "This build isn't code-signed, so it can't verify updates."
		case .noAppInArchive: "The downloaded archive doesn't contain an app."
		case .archiveTooLarge: "The downloaded archive is unexpectedly large."
		case .verificationFailed(let reason): "The downloaded app failed signature verification: \(reason)."
		case .extractionFailed(let reason): "Couldn't unpack the update: \(reason)."
		}
	}
}

enum UpdatePhase {
	case downloading
	case verifying
	case installing
}

// Pure command construction (unit-tested); process spawning lives in SelfUpdater.
enum SelfUpdate {
	static func relaunchScript(pid: Int32, appPath: String) -> String {
		let quoted = "'" + appPath.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
		return "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \(quoted)"
	}
}

// Downloads a release zip, verifies the contained app is signed by the same
// identity as the running app, and swaps it into place. Thin I/O wrapper in
// the SystemProxyManager/CATrustManager mould; AppState drives the phases.
struct SelfUpdater {
	private static let maxArchiveBytes: Int64 = 100 << 20

	// Full flow. Returns the installed bundle URL, ready to relaunch.
	func installUpdate(from downloadURL: URL, onPhase: @MainActor @Sendable (UpdatePhase) -> Void) async throws -> URL {
		let installed = Bundle.main.bundleURL
		guard installed.pathExtension == "app" else { throw SelfUpdateError.notInstalledAsApp }
		// Resolve the host requirement before downloading so unsigned builds
		// fail fast (and fall back to a browser download) without the transfer.
		let requirement = try Self.hostRequirement()

		await onPhase(.downloading)
		let extracted = try await Self.downloadAndExtract(downloadURL)
		defer { try? FileManager.default.removeItem(at: extracted) }

		await onPhase(.verifying)
		let newApp = try Self.findAppBundle(in: extracted)
		try Self.verify(bundleAt: newApp, satisfies: requirement)

		await onPhase(.installing)
		try Self.swapBundle(installedAt: installed, withNewAt: newApp)
		return installed
	}

	static func findAppBundle(in directory: URL) throws -> URL {
		let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
		guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
			throw SelfUpdateError.noAppInArchive
		}
		return app
	}

	// The downloaded app must satisfy the running app's designated requirement —
	// same bundle identifier, signed by the same team. Without this check,
	// replace-and-relaunch would run whatever the network handed us.
	static func verify(bundleAt url: URL, satisfies requirement: SecRequirement) throws {
		var staticCode: SecStaticCode?
		var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
		guard status == errSecSuccess, let code = staticCode else {
			throw SelfUpdateError.verificationFailed(securityErrorMessage(status))
		}
		let deepCheck = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
		status = SecStaticCodeCheckValidity(code, deepCheck, requirement)
		guard status == errSecSuccess else {
			throw SelfUpdateError.verificationFailed(securityErrorMessage(status))
		}
	}

	// Replaces the installed bundle. The old bundle moves aside into the temp
	// directory rather than being deleted, and moves back if the install fails.
	static func swapBundle(installedAt installed: URL, withNewAt new: URL) throws {
		let fm = FileManager.default
		let aside = fm.temporaryDirectory.appendingPathComponent("ProxyLight-replaced-\(UUID().uuidString)")
		try fm.moveItem(at: installed, to: aside)
		do {
			try fm.moveItem(at: new, to: installed)
		} catch {
			try? fm.moveItem(at: aside, to: installed)
			throw error
		}
	}

	// Orphaned on our exit and adopted by launchd, so it survives termination:
	// waits for our PID to die, then opens the freshly installed app.
	static func spawnRelauncher(appPath: String) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = ["-c", SelfUpdate.relaunchScript(pid: ProcessInfo.processInfo.processIdentifier, appPath: appPath)]
		try process.run()
	}

	private static func hostRequirement() throws -> SecRequirement {
		var selfCode: SecCode?
		guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let code = selfCode else {
			throw SelfUpdateError.unsignedHostApp
		}
		var staticSelf: SecStaticCode?
		guard SecCodeCopyStaticCode(code, [], &staticSelf) == errSecSuccess, let staticCode = staticSelf else {
			throw SelfUpdateError.unsignedHostApp
		}
		var requirement: SecRequirement?
		guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let host = requirement else {
			throw SelfUpdateError.unsignedHostApp
		}
		return host
	}

	private static func downloadAndExtract(_ url: URL) async throws -> URL {
		let (archive, response) = try await UpdateChecker.session.download(from: url)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw UpdateError.badStatus(http.statusCode)
		}
		let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
		let size = (attributes[.size] as? Int64) ?? 0
		guard size <= Self.maxArchiveBytes else { throw SelfUpdateError.archiveTooLarge }
		let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyLight-update-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
		try await extractZip(at: archive, to: workDir)
		return workDir
	}

	// ditto preserves the signature, resource forks and extended attributes —
	// the standard way to unpack a signed .app zip.
	private static func extractZip(at zip: URL, to destination: URL) async throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
		process.arguments = ["-x", "-k", zip.path, destination.path]
		let stderr = Pipe()
		process.standardError = stderr
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			process.terminationHandler = { finished in
				if finished.terminationStatus == 0 {
					continuation.resume()
				} else {
					let output = stderr.fileHandleForReading.readDataToEndOfFile()
					continuation.resume(throwing: SelfUpdateError.extractionFailed(String(decoding: output, as: UTF8.self)))
				}
			}
			do {
				try process.run()
			} catch {
				continuation.resume(throwing: error)
			}
		}
	}

	private static func securityErrorMessage(_ status: OSStatus) -> String {
		SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
	}
}
