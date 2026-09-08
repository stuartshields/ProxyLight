import Testing
import Foundation
@testable import ProxyLightCore

private func makeTempDir() throws -> URL {
	let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyOrchestratorTests-\(UUID().uuidString)")
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

@Test func loadsDefaultConfigInFreshDirectory() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	#expect(orchestrator.config == .defaultConfig)
}

@Test func addMappingPersistsAcrossInstances() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }

	let first = ProxyOrchestrator(directory: dir)
	first.addMapping(from: "https://a.dev/*", to: "https://a.org/*", mode: .rewrite)
	#expect(first.config.mappings.count == 1)

	let second = ProxyOrchestrator(directory: dir)
	#expect(second.config.mappings.count == 1)
	#expect(second.config.mappings[0].from == "https://a.dev/*")
}

@Test func updateMappingChangesExistingEntry() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	orchestrator.addMapping(from: "https://a.dev/*", to: "https://a.org/*", mode: .rewrite)
	let id = orchestrator.config.mappings[0].id

	orchestrator.updateMapping(id: id, from: "https://b.dev/*", to: "https://b.org/*", mode: .fallbackOnNotFound)

	#expect(orchestrator.config.mappings[0].from == "https://b.dev/*")
	#expect(orchestrator.config.mappings[0].mode == .fallbackOnNotFound)
}

@Test func deleteMappingRemovesEntry() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	orchestrator.addMapping(from: "https://a.dev/*", to: "https://a.org/*", mode: .rewrite)
	let id = orchestrator.config.mappings[0].id

	orchestrator.deleteMapping(id)

	#expect(orchestrator.config.mappings.isEmpty)
}

@Test func exportAndDecodeRoundTrip() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	orchestrator.addMapping(from: "https://a.dev/*", to: "https://a.org/*", mode: .rewrite)

	let data = try orchestrator.exportData(orchestrator.config.mappings)
	let decoded = try orchestrator.decodeImportFile(data)

	#expect(decoded.count == 1)
	#expect(decoded[0].from == "https://a.dev/*")
}

@Test func completeImportMergesIntoConfig() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	let imported = [Mapping(from: "https://c.dev/*", to: "https://c.org/*", mode: .rewrite)]

	let result = orchestrator.completeImport(accepted: imported)

	#expect(result.added == 1)
	#expect(orchestrator.config.mappings.count == 1)
}

@Test func startBindsAPortAndStopReleasesIt() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	orchestrator.config.listenPort = 0 // let the OS choose a free port

	let port = try orchestrator.start()
	#expect(port > 0)
	#expect(orchestrator.isRunning)
	#expect(orchestrator.runningPort == port)

	try orchestrator.stop()
	#expect(!orchestrator.isRunning)
	#expect(orchestrator.runningPort == nil)
}

@Test func pacURLIsNilUntilRunning() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	#expect(orchestrator.pacURL() == nil)

	orchestrator.config.listenPort = 0
	let port = try orchestrator.start()
	defer { try? orchestrator.stop() }
	#expect(orchestrator.pacURL() == "http://127.0.0.1:\(port)/proxy.pac?v=1")
}

@Test func rootCertificatePEMIsAvailable() throws {
	let dir = try makeTempDir()
	defer { try? FileManager.default.removeItem(at: dir) }
	let orchestrator = ProxyOrchestrator(directory: dir)
	#expect(orchestrator.rootCertificatePEM.contains("BEGIN CERTIFICATE"))
}
