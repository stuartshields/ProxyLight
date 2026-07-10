import Foundation
import Security
import Testing
@testable import ProxyLight

private func makeTempDir() throws -> URL {
	let url = FileManager.default.temporaryDirectory.appendingPathComponent("SelfUpdaterTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

@Test func relaunchScriptWaitsForPidThenOpensApp() {
	let script = SelfUpdate.relaunchScript(pid: 123, appPath: "/Applications/ProxyLight.app")
	#expect(script == "while /bin/kill -0 123 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open '/Applications/ProxyLight.app'")
}

@Test func relaunchScriptEscapesSingleQuotesInPath() {
	let script = SelfUpdate.relaunchScript(pid: 1, appPath: "/Apps/O'Brien.app")
	#expect(script.contains(#"'/Apps/O'\''Brien.app'"#))
}

@Test func findsAppBundleInExtractedArchive() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let app = dir.appendingPathComponent("ProxyLight.app")
	try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
	#expect(try SelfUpdater.findAppBundle(in: dir).lastPathComponent == "ProxyLight.app")
}

@Test func missingAppBundleThrows() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	#expect(throws: SelfUpdateError.self) {
		try SelfUpdater.findAppBundle(in: dir)
	}
}

@Test func swapReplacesInstalledBundleContents() throws {
	let root = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: root) }
	let installed = root.appendingPathComponent("Installed/ProxyLight.app")
	let extracted = root.appendingPathComponent("Extracted/ProxyLight.app")
	try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
	try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
	try Data("new".utf8).write(to: extracted.appendingPathComponent("marker"))

	try SelfUpdater.swapBundle(installedAt: installed, withNewAt: extracted)

	let marker = try Data(contentsOf: installed.appendingPathComponent("marker"))
	#expect(String(decoding: marker, as: UTF8.self) == "new")
}

@Test func unsignedBundleFailsSignatureVerification() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let app = dir.appendingPathComponent("Fake.app")
	try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
	var requirement: SecRequirement?
	SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
	let anchorApple = try #require(requirement)
	#expect(throws: SelfUpdateError.self) {
		try SelfUpdater.verify(bundleAt: app, satisfies: anchorApple)
	}
}
