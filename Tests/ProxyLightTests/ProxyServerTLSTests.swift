import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
@testable import ProxyLight

@Test func connectToUnmappedHostBlindTunnels() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }

	// A raw TCP origin that replies "PONG" to any bytes.
	let origin = try ServerBootstrap(group: group)
		.childChannelInitializer { channel in
			channel.eventLoop.makeCompletedFuture {
				try channel.pipeline.syncOperations.addHandler(PongHandler())
			}
		}
		.bind(host: "127.0.0.1", port: 0).wait()
	defer { try? origin.close().wait() }
	let originPort = origin.localAddress!.port!

	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: []) }, ca: nil)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	let reply = try connectThenSend(proxyPort: proxyPort, target: "127.0.0.1:\(originPort)", payload: "PING", group: group)
	#expect(reply.contains("PONG"))
}

private final class PongHandler: ChannelInboundHandler {
	typealias InboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer
	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		var out = context.channel.allocator.buffer(capacity: 4)
		out.writeString("PONG")
		context.writeAndFlush(wrapOutboundOut(out), promise: nil)
	}
}

// Sends CONNECT, expects 200, then sends payload over the tunnel and returns the raw reply.
private func connectThenSend(proxyPort: Int, target: String, payload: String, group: EventLoopGroup) throws -> String {
	final class Collector: ChannelInboundHandler {
		typealias InboundIn = ByteBuffer
		let promise: EventLoopPromise<String>
		var acc = ""
		var sentPayload = false
		let payload: String
		init(_ p: EventLoopPromise<String>, payload: String) { promise = p; self.payload = payload }
		func channelRead(context: ChannelHandlerContext, data: NIOAny) {
			var b = unwrapInboundIn(data)
			acc += b.readString(length: b.readableBytes) ?? ""
			if !sentPayload, acc.contains("200") {
				sentPayload = true
				var buf = context.channel.allocator.buffer(capacity: payload.utf8.count)
				buf.writeString(payload)
				context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
			}
			if acc.contains("PONG") { promise.succeed(acc) }
		}
		typealias OutboundOut = ByteBuffer
	}
	let promise = group.next().makePromise(of: String.self)
	let channel = try ClientBootstrap(group: group)
		.channelInitializer { channel in
			channel.eventLoop.makeCompletedFuture {
				try channel.pipeline.syncOperations.addHandler(Collector(promise, payload: payload))
			}
		}
		.connect(host: "127.0.0.1", port: proxyPort).wait()
	let connect = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
	var buf = channel.allocator.buffer(capacity: connect.utf8.count)
	buf.writeString(connect)
	try channel.writeAndFlush(buf).wait()
	return try promise.futureResult.wait()
}

// MARK: - Shared test helpers (MITM smoke test + CONNECT dispatch regression)

// A test-runner watchdog: bounds both tests below so a hang (a TLS handshake
// that never completes, or a CONNECT that's mis-dispatched and never answers
// "200") fails the test instead of blocking the suite forever.
private struct TLSTestTimeoutError: Error {}

private enum TunnelledRequestError: Error {
	case connectNotEstablished(String)
}

// Minimal plain-HTTP origin that echoes the request URI + Host header it
// received — same pattern as the echo origin in ProxyServerHTTPTests.swift.
// Used as the terminus a mapped request lands on, whether the inbound leg
// was plain HTTP or (after MITM termination) decrypted HTTPS.
private func startPlainEchoOrigin(group: EventLoopGroup) throws -> (channel: Channel, port: Int) {
	let bootstrap = ServerBootstrap(group: group)
		.serverChannelOption(ChannelOptions.backlog, value: 16)
		.childChannelInitializer { channel in
			channel.eventLoop.makeCompletedFuture {
				try channel.pipeline.syncOperations.configureHTTPServerPipeline()
				try channel.pipeline.syncOperations.addHandler(PlainEchoOriginHandler())
			}
		}
	let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
	return (channel, channel.localAddress!.port!)
}

private final class PlainEchoOriginHandler: ChannelInboundHandler {
	typealias InboundIn = HTTPServerRequestPart
	typealias OutboundOut = HTTPServerResponsePart
	private var body = ""
	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch unwrapInboundIn(data) {
		case .head(let head):
			body = "\(head.uri)|\(head.headers.first(name: "Host") ?? "")"
		case .body: break
		case .end:
			var headers = HTTPHeaders()
			headers.add(name: "Content-Length", value: String(body.utf8.count))
			context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
			var buf = context.channel.allocator.buffer(capacity: body.utf8.count)
			buf.writeString(body)
			context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
			context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
		}
	}
}

// True once `text` contains a full HTTP/1.1 response (status line + headers
// + a Content-Length body) — the only framing the origins in this file ever
// produce, so this is all the parsing the tests below need.
private func isCompleteHTTPResponse(_ text: String) -> Bool {
	guard let headerEnd = text.range(of: "\r\n\r\n") else { return false }
	let headerPart = text[text.startIndex..<headerEnd.lowerBound]
	var contentLength = 0
	for line in headerPart.split(separator: "\r\n") {
		if line.lowercased().hasPrefix("content-length:"), let colon = line.firstIndex(of: ":") {
			contentLength = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
		}
	}
	return text.distance(from: headerEnd.upperBound, to: text.endIndex) >= contentLength
}

// MARK: - MITM smoke test

// End-to-end MITM coverage: real CONNECT -> TLS handshake against the
// CA-issued leaf -> decrypted inner HTTP request -> mapping rewrite ->
// plain-TCP forward to the origin -> response streamed back through the
// same encrypted tunnel. Mapping the https inbound host straight to a plain
// http origin avoids needing an upstream TLS stub: the rewrite carries the
// target scheme, so ProxyGlueHandler forwards over plain TCP once the
// mapping resolves to "http://...".
@Test func mitmTerminatesTLSAndForwardsRewrittenRequestToPlainOrigin() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }

	let (origin, originPort) = try startPlainEchoOrigin(group: group)
	defer { try? origin.close().wait() }

	let caDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	defer { try? FileManager.default.removeItem(at: caDir) }
	let ca = try CertificateAuthority(directory: caDir)

	let mapping = Mapping(
		from: "https://mapped.test/api/*",
		to: "http://127.0.0.1:\(originPort)/api/*",
		enabled: true
	)
	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: ca)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	// Trust the CA's root so the client-side handshake performs full
	// verification against the CA-issued leaf (SAN == "mapped.test").
	let rootCert = try NIOSSLCertificate(bytes: Array(ca.rootCertificatePEM.utf8), format: .pem)
	var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
	clientTLSConfig.trustRoots = .certificates([rootCert])
	let clientContext = try NIOSSLContext(configuration: clientTLSConfig)

	let response = try performTunnelledTLSRequest(
		proxyPort: proxyPort,
		connectTarget: "mapped.test:443",
		sniHostname: "mapped.test",
		innerRequestRaw: "GET /api/thing?x=1 HTTP/1.1\r\nHost: mapped.test\r\n\r\n",
		sslContext: clientContext,
		group: group
	)

	// Proves the decrypted inner request was parsed, the mapping rewrote it
	// to the plain origin, and the origin's response streamed back through
	// the same encrypted tunnel.
	#expect(response.contains("/api/thing?x=1"))
	#expect(response.contains("127.0.0.1:\(originPort)"))
}

// Drives CONNECT -> TLS handshake -> inner HTTP request/response over ONE
// raw TCP channel to the proxy: sends the CONNECT line, waits for "200",
// inserts a NIOSSLClientHandler ahead of itself in the pipeline (closer to
// the socket, so this handler's writes get encrypted and inbound bytes get
// decrypted before this handler's channelRead sees them — mirroring how
// ProxyGlueHandler.openUpstream layers NIOSSLClientHandler for its own
// upstream connections), then writes the plaintext inner request and
// collects the decrypted response. NIOSSLClientHandler buffers outbound
// writes made before the handshake completes and flushes them once it does
// (the same assumption ProxyGlueHandler.openUpstream relies on), so no
// explicit "wait for handshake" step is needed here.
private func performTunnelledTLSRequest(proxyPort: Int, connectTarget: String, sniHostname: String, innerRequestRaw: String, sslContext: NIOSSLContext, group: EventLoopGroup, timeout: TimeAmount = .seconds(5)) throws -> String {
	let promise = group.next().makePromise(of: String.self)
	let channel = try ClientBootstrap(group: group)
		.channelInitializer { channel in
			channel.eventLoop.makeCompletedFuture {
				try channel.pipeline.syncOperations.addHandler(TunnelledTLSRequestHandler(
					connectTarget: connectTarget,
					sniHostname: sniHostname,
					sslContext: sslContext,
					innerRequestRaw: innerRequestRaw,
					promise: promise
				))
			}
		}
		.connect(host: "127.0.0.1", port: proxyPort).wait()
	defer { try? channel.close().wait() }

	let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
		promise.fail(TLSTestTimeoutError())
	}
	promise.futureResult.whenComplete { _ in timeoutTask.cancel() }

	return try promise.futureResult.wait()
}

private final class TunnelledTLSRequestHandler: ChannelInboundHandler {
	typealias InboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	private enum Phase {
		case awaitingConnectResponse
		case tunnelling
	}

	private var phase = Phase.awaitingConnectResponse
	private var acc = ""
	private let connectTarget: String
	private let sniHostname: String
	private let sslContext: NIOSSLContext
	private let innerRequestRaw: String
	private let promise: EventLoopPromise<String>

	init(connectTarget: String, sniHostname: String, sslContext: NIOSSLContext, innerRequestRaw: String, promise: EventLoopPromise<String>) {
		self.connectTarget = connectTarget
		self.sniHostname = sniHostname
		self.sslContext = sslContext
		self.innerRequestRaw = innerRequestRaw
		self.promise = promise
	}

	func channelActive(context: ChannelHandlerContext) {
		let connectRaw = "CONNECT \(connectTarget) HTTP/1.1\r\nHost: \(connectTarget)\r\n\r\n"
		var buf = context.channel.allocator.buffer(capacity: connectRaw.utf8.count)
		buf.writeString(connectRaw)
		context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		var buffer = unwrapInboundIn(data)
		acc += buffer.readString(length: buffer.readableBytes) ?? ""
		switch phase {
		case .awaitingConnectResponse:
			guard acc.contains("\r\n\r\n") else { return }
			guard acc.hasPrefix("HTTP/1.1 200") else {
				promise.fail(TunnelledRequestError.connectNotEstablished(acc))
				return
			}
			phase = .tunnelling
			acc = ""
			startTLSThenSendInnerRequest(context: context)
		case .tunnelling:
			if isCompleteHTTPResponse(acc) {
				promise.succeed(acc)
			}
		}
	}

	private func startTLSThenSendInnerRequest(context: ChannelHandlerContext) {
		// channelRead runs on the channel's loop, so the SSL handler can be
		// inserted synchronously and the inner request written right after.
		do {
			let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: sniHostname)
			try context.pipeline.syncOperations.addHandler(ssl, position: .first)
			var buf = context.channel.allocator.buffer(capacity: innerRequestRaw.utf8.count)
			buf.writeString(innerRequestRaw)
			context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
		} catch {
			promise.fail(error)
		}
	}

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		promise.fail(error)
	}
}

// MARK: - CONNECT-after-plain-request dispatch regression

// Regression for the bug where ConnectHandler.channelRead short-circuited
// EVERY read once plain-HTTP glue was installed, including a later `.head`:
// a CONNECT reusing an already-glued keep-alive connection was routed to
// ProxyGlueHandler — which opened a plain TCP connection and wrote a literal
// "CONNECT ..." request line — instead of being tunnelled. Before the fix,
// no "200 Connection Established" is ever produced for the CONNECT, so this
// test times out and fails with TLSTestTimeoutError; after the fix it
// tunnels correctly and passes.
@Test func connectAfterPlainRequestOnSameKeepAliveConnectionStillTunnels() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }

	let (httpOrigin, httpOriginPort) = try startPlainEchoOrigin(group: group)
	defer { try? httpOrigin.close().wait() }

	// Raw TCP origin for the CONNECT target that follows on the SAME
	// connection as the plain request below.
	let tunnelOrigin = try ServerBootstrap(group: group)
		.childChannelInitializer { channel in
			channel.eventLoop.makeCompletedFuture {
				try channel.pipeline.syncOperations.addHandler(PongHandler())
			}
		}
		.bind(host: "127.0.0.1", port: 0).wait()
	defer { try? tunnelOrigin.close().wait() }
	let tunnelOriginPort = tunnelOrigin.localAddress!.port!

	let mapping = Mapping(
		from: "http://local.test/api/*",
		to: "http://127.0.0.1:\(httpOriginPort)/api/*",
		enabled: true
	)
	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	let result = try plainRequestThenConnectOnSameConnection(
		proxyPort: proxyPort,
		plainRequestRaw: "GET http://local.test/api/thing HTTP/1.1\r\nHost: local.test\r\n\r\n",
		connectTarget: "127.0.0.1:\(tunnelOriginPort)",
		tunnelPayload: "PING",
		group: group
	)

	#expect(result.plainResponse.contains("200"))
	#expect(result.tunnelReply.contains("PONG"))
}

// Sends `plainRequestRaw` first (installing plain-HTTP glue, per the bug
// description) and waits for its complete response, then — on the SAME raw
// TCP connection — sends a CONNECT to `connectTarget`, waits for "200", and
// sends `tunnelPayload` through the tunnel, returning both responses.
private func plainRequestThenConnectOnSameConnection(proxyPort: Int, plainRequestRaw: String, connectTarget: String, tunnelPayload: String, group: EventLoopGroup, timeout: TimeAmount = .seconds(5)) throws -> (plainResponse: String, tunnelReply: String) {
	let plainResponsePromise = group.next().makePromise(of: String.self)
	let tunnelReplyPromise = group.next().makePromise(of: String.self)

	let channel = try ClientBootstrap(group: group)
		.channelInitializer { channel in
			channel.eventLoop.makeCompletedFuture {
				try channel.pipeline.syncOperations.addHandler(PlainThenConnectHandler(
					plainRequestRaw: plainRequestRaw,
					connectTarget: connectTarget,
					tunnelPayload: tunnelPayload,
					plainResponsePromise: plainResponsePromise,
					tunnelReplyPromise: tunnelReplyPromise
				))
			}
		}
		.connect(host: "127.0.0.1", port: proxyPort).wait()
	defer { try? channel.close().wait() }

	let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
		plainResponsePromise.fail(TLSTestTimeoutError())
		tunnelReplyPromise.fail(TLSTestTimeoutError())
	}
	tunnelReplyPromise.futureResult.whenComplete { _ in timeoutTask.cancel() }

	let plainResponse = try plainResponsePromise.futureResult.wait()
	let tunnelReply = try tunnelReplyPromise.futureResult.wait()
	return (plainResponse, tunnelReply)
}

private final class PlainThenConnectHandler: ChannelInboundHandler {
	typealias InboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	private enum Phase {
		case awaitingPlainResponse
		case awaitingConnectResponse
		case awaitingTunnelReply
	}

	private var phase = Phase.awaitingPlainResponse
	private var acc = ""
	private let plainRequestRaw: String
	private let connectTarget: String
	private let tunnelPayload: String
	private let plainResponsePromise: EventLoopPromise<String>
	private let tunnelReplyPromise: EventLoopPromise<String>

	init(plainRequestRaw: String, connectTarget: String, tunnelPayload: String, plainResponsePromise: EventLoopPromise<String>, tunnelReplyPromise: EventLoopPromise<String>) {
		self.plainRequestRaw = plainRequestRaw
		self.connectTarget = connectTarget
		self.tunnelPayload = tunnelPayload
		self.plainResponsePromise = plainResponsePromise
		self.tunnelReplyPromise = tunnelReplyPromise
	}

	func channelActive(context: ChannelHandlerContext) {
		var buf = context.channel.allocator.buffer(capacity: plainRequestRaw.utf8.count)
		buf.writeString(plainRequestRaw)
		context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		var buffer = unwrapInboundIn(data)
		acc += buffer.readString(length: buffer.readableBytes) ?? ""
		switch phase {
		case .awaitingPlainResponse:
			guard isCompleteHTTPResponse(acc) else { return }
			plainResponsePromise.succeed(acc)
			phase = .awaitingConnectResponse
			acc = ""
			let connectRaw = "CONNECT \(connectTarget) HTTP/1.1\r\nHost: \(connectTarget)\r\n\r\n"
			var buf = context.channel.allocator.buffer(capacity: connectRaw.utf8.count)
			buf.writeString(connectRaw)
			context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
		case .awaitingConnectResponse:
			guard acc.contains("\r\n\r\n") else { return }
			guard acc.hasPrefix("HTTP/1.1 200") else {
				tunnelReplyPromise.fail(TunnelledRequestError.connectNotEstablished(acc))
				return
			}
			phase = .awaitingTunnelReply
			acc = ""
			var buf = context.channel.allocator.buffer(capacity: tunnelPayload.utf8.count)
			buf.writeString(tunnelPayload)
			context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
		case .awaitingTunnelReply:
			if acc.contains("PONG") {
				tunnelReplyPromise.succeed(acc)
			}
		}
	}
}

// Regression: the CONNECT 200 response must carry NO body framing. A chunked
// 200 (NIO's default for an HTTP/1.1 200 with no Content-Length) makes `.end`
// inject the empty-chunk terminator "0\r\n\r\n" into the tunnel; the client
// reads those bytes as a malformed first TLS record and aborts the handshake
// with a "protocol version" alert, so every MITM'd HTTPS page fails to load.
// Before the fix this test sees "transfer-encoding: chunked" plus trailing
// "0\r\n\r\n"; after it, the response ends cleanly at the header terminator.
@Test func connectResponseCarriesNoBodyFramingIntoTunnel() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }
	let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
	defer { try? FileManager.default.removeItem(at: dir) }
	let ca = try CertificateAuthority(directory: dir)
	// An enabled https mapping for this host routes the CONNECT through the MITM
	// path (respondConnectEstablished). The upstream target is never contacted —
	// the test only inspects the CONNECT response bytes.
	let mapping = Mapping(from: "https://mapped.test/x/*", to: "http://127.0.0.1:9/x/*", enabled: true)
	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: ca)
	let port = try server.start()
	defer { try? server.stop() }

	let response = try readConnectResponse(proxyPort: port, connectTarget: "mapped.test:443", group: group)
	#expect(response.contains("200"))
	#expect(!response.lowercased().contains("transfer-encoding: chunked"))
	guard let headerEnd = response.range(of: "\r\n\r\n") else {
		Issue.record("no header terminator in CONNECT response: \(response)")
		return
	}
	#expect(String(response[headerEnd.upperBound...]).isEmpty)
}

private func readConnectResponse(proxyPort: Int, connectTarget: String, group: EventLoopGroup) throws -> String {
	// @unchecked Sendable: constructed on the test thread but its mutable state
	// (acc/done) is only ever touched on the channel's event loop — channelRead
	// runs there, and timeout() fires from scheduleTask on that same loop.
	final class Collector: ChannelInboundHandler, @unchecked Sendable {
		typealias InboundIn = ByteBuffer
		typealias OutboundOut = ByteBuffer
		let promise: EventLoopPromise<String>
		let target: String
		var acc = ""
		var done = false
		init(_ p: EventLoopPromise<String>, target: String) { promise = p; self.target = target }
		func channelActive(context: ChannelHandlerContext) {
			var buf = context.channel.allocator.buffer(capacity: 64)
			buf.writeString("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
			context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
		}
		func channelRead(context: ChannelHandlerContext, data: NIOAny) {
			var b = unwrapInboundIn(data)
			acc += b.readString(length: b.readableBytes) ?? ""
			finish()
		}
		func finish() {
			guard !done, acc.contains("\r\n\r\n") else { return }
			done = true
			promise.succeed(acc)
		}
		// Fires only if the response never arrives; succeeds with whatever was
		// collected so the assertions run and fail with a useful message.
		func timeout() {
			guard !done else { return }
			done = true
			promise.succeed(acc)
		}
	}
	let promise = group.next().makePromise(of: String.self)
	let collector = Collector(promise, target: connectTarget)
	let channel = try ClientBootstrap(group: group)
		.channelInitializer { $0.pipeline.addHandler(collector) }
		.connect(host: "127.0.0.1", port: proxyPort).wait()
	let timeoutTask = channel.eventLoop.scheduleTask(in: .seconds(5)) { collector.timeout() }
	let result = try promise.futureResult.wait()
	timeoutTask.cancel()
	try? channel.close().wait()
	return result
}
