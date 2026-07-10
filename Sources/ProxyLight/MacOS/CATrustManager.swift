import Foundation
import Security

enum CATrustError: Error, LocalizedError {
	case commandFailed(String)

	var errorDescription: String? {
		switch self {
		case .commandFailed(let message): return message
		}
	}
}

struct CATrustManager {
	private let runner: CommandRunner

	init(runner: CommandRunner = ProcessRunner()) {
		self.runner = runner
	}

	// Trusts the CA root for the CURRENT USER (login keychain, user trust
	// domain). This deliberately avoids the System/admin trust domain (the `-d`
	// flag): writing admin-domain trust settings goes through
	// SecTrustSettingsSetTrustSettings, which needs an interactive authorization
	// session a background/spawned process can't provide — it fails with
	// "The authorization was denied since no user interaction was possible."
	// User-domain trust is set by the app running as the user, needs no admin,
	// and is honored by Safari and Chrome for that user.
	func trust(certificateURL: URL) throws {
		let command = Self.trustCommand(
			certificatePath: certificateURL.path,
			loginKeychainPath: Self.loginKeychainPath
		)
		do {
			_ = try runner.run(command.launchPath, command.args)
		} catch let CommandError.nonZeroExit(cmd, status, stderr) {
			throw CATrustError.commandFailed("'\(cmd)' exited with status \(status): \(stderr)")
		} catch {
			throw CATrustError.commandFailed(error.localizedDescription)
		}
	}

	// Reports whether the CA root currently has user-domain trust settings —
	// the state trust(certificateURL:) establishes. Queries the keychain
	// read-only, so it's safe to call at every launch; it stays truthful if the
	// user revokes trust in Keychain Access or the CA is regenerated.
	func isTrusted(certificateURL: URL) -> Bool {
		guard let pem = try? String(contentsOf: certificateURL, encoding: .utf8),
			let der = Self.derBytes(fromPEM: pem),
			let certificate = SecCertificateCreateWithData(nil, der as CFData)
		else { return false }
		var settings: CFArray?
		return SecTrustSettingsCopyTrustSettings(certificate, .user, &settings) == errSecSuccess
	}

	// Strips the PEM armor and decodes the base64 body. Pure so the
	// PEM-to-SecCertificate path is unit-testable without a keychain.
	static func derBytes(fromPEM pem: String) -> Data? {
		let body = pem
			.split(whereSeparator: \.isNewline)
			.filter { !$0.hasPrefix("-----") }
			.joined()
		return Data(base64Encoded: body)
	}

	static var loginKeychainPath: String {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Keychains/login.keychain-db")
			.path
	}

	// Pure so the exact argv can be unit-tested without executing anything.
	// Runs `security` directly via ProcessRunner (no shell, no osascript), so
	// the cert path and keychain path are passed as verbatim argv elements —
	// no quoting or escaping is needed and no shell can interpret them.
	static func trustCommand(certificatePath: String, loginKeychainPath: String) -> (launchPath: String, args: [String]) {
		(
			"/usr/bin/security",
			["add-trusted-cert", "-r", "trustRoot", "-k", loginKeychainPath, certificatePath]
		)
	}
}
