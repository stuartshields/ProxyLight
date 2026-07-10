import Testing
import Foundation
import Security
import X509
@testable import ProxyLight

@Test func generatesAndPersistsRoot() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	defer { try? FileManager.default.removeItem(at: dir) }

	let ca1 = try CertificateAuthority(directory: dir)
	let pem1 = ca1.rootCertificatePEM
	// Second init in same dir must reuse the same root, not regenerate.
	let ca2 = try CertificateAuthority(directory: dir)
	#expect(ca1.rootCertificatePEM == ca2.rootCertificatePEM)
	#expect(pem1.contains("BEGIN CERTIFICATE"))
}

@Test func keyFileIsOwnerReadOnly() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	defer { try? FileManager.default.removeItem(at: dir) }
	_ = try CertificateAuthority(directory: dir)
	let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ca.key").path)
	#expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func rootPEMDecodesToDERThatSecurityAccepts() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	defer { try? FileManager.default.removeItem(at: dir) }
	let ca = try CertificateAuthority(directory: dir)
	let der = try #require(CATrustManager.derBytes(fromPEM: ca.rootCertificatePEM))
	#expect(SecCertificateCreateWithData(nil, der as CFData) != nil)
}

@Test func derBytesRejectsNonPEMInput() {
	#expect(CATrustManager.derBytes(fromPEM: "not a pem") == nil)
}

@Test func freshlyGeneratedRootIsNotTrusted() throws {
	// A brand-new CA can't have trust settings in the user's keychain yet, so
	// the read-only trust query must report false (and must not throw or hang).
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	defer { try? FileManager.default.removeItem(at: dir) }
	let ca = try CertificateAuthority(directory: dir)
	#expect(CATrustManager().isTrusted(certificateURL: ca.rootCertificateURL) == false)
}

@Test func mintsLeafServerContextForHost() throws {
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	defer { try? FileManager.default.removeItem(at: dir) }
	let ca = try CertificateAuthority(directory: dir)
	// Should not throw and should be cached (same object on second call path exercised).
	let ctx1 = try ca.serverContext(forHost: "example.test")
	let ctx2 = try ca.serverContext(forHost: "example.test")
	#expect(ctx1 === ctx2)
}
