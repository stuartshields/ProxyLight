import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import ProxyLightCore

// Pure dispatch-rule tests (fast; not in the serialized suite).
@Test func originFormURIIsSelfAddressed() {
	#expect(PACResponder.isSelfAddressed(uri: "/proxy.pac?v=2", boundPort: 9876))
	#expect(PACResponder.isSelfAddressed(uri: "/anything", boundPort: 9876))
}

@Test func absoluteFormLoopbackWithBoundPortIsSelfAddressed() {
	#expect(PACResponder.isSelfAddressed(uri: "http://127.0.0.1:9876/proxy.pac", boundPort: 9876))
	#expect(PACResponder.isSelfAddressed(uri: "http://LOCALHOST:9876/x", boundPort: 9876))
}

@Test func absoluteFormOtherTargetsAreNotSelfAddressed() {
	#expect(!PACResponder.isSelfAddressed(uri: "http://example.com/", boundPort: 9876))
	#expect(!PACResponder.isSelfAddressed(uri: "http://127.0.0.1:8080/", boundPort: 9876))
	// CONNECT authority-form ("host:port") is neither origin-form nor loopback.
	#expect(!PACResponder.isSelfAddressed(uri: "example.com:443", boundPort: 9876))
}

// These stand up a real proxy and block on .wait() — serialized, like the
// other integration suites (see ProxyServerHTTPTests.FallbackModeTests).
@Suite(.serialized)
struct PACServingTests {
	@Test func servesPACWithCurrentMappingsDirectly() throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let box = MappingsBox([
			Mapping(from: "https://myapp.example.com/tachyon/*", to: "https://origin.example.net/tachyon/*"),
		])
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: box.get()) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let response = try directRequest(port: proxyPort,
			raw: "GET /proxy.pac?v=1 HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\nConnection: close\r\n\r\n",
			group: group)
		#expect(response.contains("200 OK"))
		#expect(response.contains("application/x-ns-proxy-autoconfig"))
		#expect(response.contains("\"myapp.example.com\": 1"))
		#expect(response.contains("PROXY 127.0.0.1:\(proxyPort)"))

		// A mapping edit through the live box changes the next served PAC.
		box.set([Mapping(from: "https://other.example.com/a/*", to: "https://r.example.net/a/*")])
		let updated = try directRequest(port: proxyPort,
			raw: "GET /proxy.pac?v=2 HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\nConnection: close\r\n\r\n",
			group: group)
		#expect(updated.contains("\"other.example.com\": 1"))
		#expect(!updated.contains("myapp.example.com"))
	}

	@Test func selfAddressedNonPACPathReturns404() throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: []) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let response = try directRequest(port: proxyPort,
			raw: "GET /anything-else HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\nConnection: close\r\n\r\n",
			group: group)
		#expect(response.contains("404"))
	}
}

// Raw-socket request to the listener itself; accumulates until the server
// closes, with a hard 5s deadline (the channel is force-closed) so a
// misbehaving server can never hang the suite. (Private copy — the equivalent
// helper in ProxyServerHTTPTests is file-private.)
private func directRequest(port: Int, raw: String, group: EventLoopGroup) throws -> String {
	final class Collector: ChannelInboundHandler {
		typealias InboundIn = ByteBuffer
		private var acc = ""
		private let promise: EventLoopPromise<String>
		init(promise: EventLoopPromise<String>) { self.promise = promise }
		func channelRead(context: ChannelHandlerContext, data: NIOAny) {
			var buf = unwrapInboundIn(data)
			acc += buf.readString(length: buf.readableBytes) ?? ""
		}
		func channelInactive(context: ChannelHandlerContext) { promise.succeed(acc) }
	}
	let promise = group.next().makePromise(of: String.self)
	let channel = try ClientBootstrap(group: group)
		.channelInitializer { channel in
			channel.eventLoop.makeCompletedFuture {
				try channel.pipeline.syncOperations.addHandler(Collector(promise: promise))
			}
		}
		.connect(host: "127.0.0.1", port: port).wait()
	channel.eventLoop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
	var buffer = channel.allocator.buffer(capacity: raw.utf8.count)
	buffer.writeString(raw)
	try channel.writeAndFlush(buffer).wait()
	return try promise.futureResult.wait()
}
