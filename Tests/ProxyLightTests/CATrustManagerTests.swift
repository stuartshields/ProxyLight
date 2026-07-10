import Testing
import Foundation
import Security
import X509
@testable import ProxyLightCore
@testable import ProxyLight

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
