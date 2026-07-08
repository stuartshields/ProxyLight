import Foundation

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
