import Foundation
import Testing
@testable import ProxyLight

private let zipURLString = "https://github.com/stuartshields/ProxyLight/releases/download/v0.1.3/ProxyLight.zip"

private func releaseJSON(tag: String, assetURL: String? = zipURLString) -> Data {
	let assets = assetURL.map { #"[{"name": "ProxyLight.zip", "browser_download_url": "\#($0)"}]"# } ?? "[]"
	return Data(#"{"tag_name": "\#(tag)", "assets": \#(assets)}"#.utf8)
}

@Test func newerRemoteVersionIsDetected() {
	#expect(UpdateCheck.isNewer("0.1.3", than: "0.1.2"))
	#expect(!UpdateCheck.isNewer("0.1.2", than: "0.1.2"))
	#expect(!UpdateCheck.isNewer("0.1.1", than: "0.1.2"))
}

@Test func versionComponentsCompareNumericallyNotLexically() {
	#expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
	#expect(!UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
}

@Test func shorterVersionsPadWithZeros() {
	#expect(!UpdateCheck.isNewer("1.0", than: "1.0.0"))
	#expect(UpdateCheck.isNewer("1.0.1", than: "1.0"))
}

@Test func devFallbackVersionSeesEveryReleaseAsNewer() {
	#expect(UpdateCheck.isNewer("0.1.2", than: "0.0.0-dev"))
}

@Test func newerReleaseYieldsDownloadableUpdate() throws {
	let update = try UpdateCheck.availableUpdate(fromReleaseJSON: releaseJSON(tag: "v0.1.3"), currentVersion: "0.1.2")
	let expectedURL = try #require(URL(string: zipURLString))
	#expect(update == AvailableUpdate(version: "0.1.3", downloadURL: expectedURL))
}

@Test func currentReleaseYieldsNoUpdate() throws {
	let update = try UpdateCheck.availableUpdate(fromReleaseJSON: releaseJSON(tag: "v0.1.2"), currentVersion: "0.1.2")
	#expect(update == nil)
}

@Test func newerReleaseWithoutZipAssetYieldsNoUpdate() throws {
	let update = try UpdateCheck.availableUpdate(fromReleaseJSON: releaseJSON(tag: "v0.1.3", assetURL: nil), currentVersion: "0.1.2")
	#expect(update == nil)
}

@Test func malformedReleaseJSONThrows() {
	#expect(throws: (any Error).self) {
		try UpdateCheck.availableUpdate(fromReleaseJSON: Data("not json".utf8), currentVersion: "0.1.2")
	}
}
