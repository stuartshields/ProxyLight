import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL

// @unchecked Sendable: every stored property is an immutable `let` except
// `leafCache`, whose every access is guarded by `lock` (see serverContext).
// Instances are shared across NIO event-loop threads by ConnectHandler.
final class CertificateAuthority: @unchecked Sendable {
	private let caPrivateKey: Certificate.PrivateKey
	private let caCertificate: Certificate
	private var leafCache: [String: NIOSSLContext] = [:]
	private let lock = NSLock()

	let rootCertificatePEM: String
	let rootCertificateURL: URL

	init(directory: URL) throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let keyURL = directory.appendingPathComponent("ca.key")
		let certURL = directory.appendingPathComponent("ca.cert.pem")
		rootCertificateURL = certURL

		if let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8),
			let certPEM = try? String(contentsOf: certURL, encoding: .utf8) {
			let p256 = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
			caPrivateKey = Certificate.PrivateKey(p256)
			caCertificate = try Certificate(pemEncoded: certPEM)
		} else {
			let p256 = P256.Signing.PrivateKey()
			let key = Certificate.PrivateKey(p256)
			let cert = try Self.makeRoot(key: key)
			try Data(p256.pemRepresentation.utf8).write(to: keyURL, options: .atomic)
			try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
			try Data(cert.serializeAsPEM().pemString.utf8).write(to: certURL, options: .atomic)
			caPrivateKey = key
			caCertificate = cert
		}
		rootCertificatePEM = try caCertificate.serializeAsPEM().pemString
	}

	func serverContext(forHost host: String) throws -> NIOSSLContext {
		lock.lock(); defer { lock.unlock() }
		if let cached = leafCache[host] { return cached }

		let leafKeyP256 = P256.Signing.PrivateKey()
		let leafKey = Certificate.PrivateKey(leafKeyP256)
		let leaf = try makeLeaf(host: host, publicKey: leafKey)

		let leafDER = try NIOSSLCertificate(bytes: Array(leaf.serializeAsPEM().derBytes), format: .der)
		let rootDER = try NIOSSLCertificate(bytes: Array(caCertificate.serializeAsPEM().derBytes), format: .der)
		let nioKey = try NIOSSLPrivateKey(bytes: Array(leafKeyP256.pemRepresentation.utf8), format: .pem)

		var config = TLSConfiguration.makeServerConfiguration(
			certificateChain: [.certificate(leafDER), .certificate(rootDER)],
			privateKey: .privateKey(nioKey)
		)
		config.applicationProtocols = ["http/1.1"]
		let context = try NIOSSLContext(configuration: config)
		leafCache[host] = context
		return context
	}

	private static func makeRoot(key: Certificate.PrivateKey) throws -> Certificate {
		let name = try DistinguishedName { CommonName("ProxyLight Local CA") }
		let now = Date()
		return try Certificate(
			version: .v3,
			serialNumber: Certificate.SerialNumber(),
			publicKey: key.publicKey,
			notValidBefore: now.addingTimeInterval(-3600),
			notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 3650),
			issuer: name,
			subject: name,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: try Certificate.Extensions {
				Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
				Critical(KeyUsage(keyCertSign: true, cRLSign: true))
			},
			issuerPrivateKey: key
		)
	}

	private func makeLeaf(host: String, publicKey key: Certificate.PrivateKey) throws -> Certificate {
		let subject = try DistinguishedName { CommonName(host) }
		let now = Date()
		return try Certificate(
			version: .v3,
			serialNumber: Certificate.SerialNumber(),
			publicKey: key.publicKey,
			notValidBefore: now.addingTimeInterval(-3600),
			notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 800),
			issuer: caCertificate.subject,
			subject: subject,
			signatureAlgorithm: .ecdsaWithSHA256,
			extensions: try Certificate.Extensions {
				Critical(BasicConstraints.notCertificateAuthority)
				KeyUsage(digitalSignature: true, keyEncipherment: true)
				try ExtendedKeyUsage([.serverAuth])
				SubjectAlternativeNames([.dnsName(host)])
			},
			issuerPrivateKey: caPrivateKey
		)
	}
}
