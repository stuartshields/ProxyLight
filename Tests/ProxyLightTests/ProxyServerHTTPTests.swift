import Testing
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import ProxyLight

// Minimal origin server that echoes the request line + Host header it received.
private func startEchoOrigin(group: EventLoopGroup) throws -> (channel: Channel, port: Int) {
	let bootstrap = ServerBootstrap(group: group)
		.serverChannelOption(ChannelOptions.backlog, value: 16)
		.childChannelInitializer { channel in
			channel.pipeline.configureHTTPServerPipeline().flatMap {
				channel.pipeline.addHandler(EchoOriginHandler())
			}
		}
	let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
	return (channel, channel.localAddress!.port!)
}

private final class EchoOriginHandler: ChannelInboundHandler {
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

// Origin server that reads the full request body and echoes it back verbatim,
// proving the request's .end (and everything before it) reached the origin.
private func startBodyEchoOrigin(group: EventLoopGroup) throws -> (channel: Channel, port: Int) {
	let bootstrap = ServerBootstrap(group: group)
		.serverChannelOption(ChannelOptions.backlog, value: 16)
		.childChannelInitializer { channel in
			channel.pipeline.configureHTTPServerPipeline().flatMap {
				channel.pipeline.addHandler(BodyEchoOriginHandler())
			}
		}
	let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
	return (channel, channel.localAddress!.port!)
}

private final class BodyEchoOriginHandler: ChannelInboundHandler {
	typealias InboundIn = HTTPServerRequestPart
	typealias OutboundOut = HTTPServerResponsePart
	private var received: ByteBuffer?
	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch unwrapInboundIn(data) {
		case .head:
			received = context.channel.allocator.buffer(capacity: 0)
		case .body(var buffer):
			received?.writeBuffer(&buffer)
		case .end:
			var buf = received ?? context.channel.allocator.buffer(capacity: 0)
			let content = buf.readString(length: buf.readableBytes) ?? ""
			var headers = HTTPHeaders()
			headers.add(name: "Content-Length", value: String(content.utf8.count))
			context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
			var outBuf = context.channel.allocator.buffer(capacity: content.utf8.count)
			outBuf.writeString(content)
			context.write(wrapOutboundOut(.body(.byteBuffer(outBuf))), promise: nil)
			context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
		}
	}
}

// A request whose header block exceeds the 64 KB cap must get a 431 and the
// connection closed, without the oversized head ever reaching an upstream.
@Test func oversizedRequestHeaderReturns431() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }

	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: []) }, ca: nil)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	// 90 KB header value comfortably exceeds the 64 KB cap; the request line
	// plus this one oversized header (with its own terminating blank line)
	// is enough to trip the guard well before the head would ever complete.
	let oversizedValue = String(repeating: "A", count: 90 * 1024)
	let raw = "GET http://x/ HTTP/1.1\r\nHost: x\r\nX-Big: \(oversizedValue)\r\n\r\n"
	let response = try sendRawRequest(proxyPort: proxyPort, raw: raw, group: group)
	guard let statusLine = response.split(separator: "\r\n", maxSplits: 1).first else {
		Issue.record("proxy returned an empty response")
		return
	}
	#expect(statusLine.contains("431"))
}

@Test func upstreamConnectionFailureReturns502() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }

	// Nothing listens on port 1 (tcpmux) on a dev machine, so the upstream
	// connect fails fast and the proxy must answer with a 502 of its own.
	let mapping = Mapping(
		from: "http://local.test/api/*",
		to: "http://127.0.0.1:1/api/*",
		enabled: true
	)
	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	let raw = try fetchThroughProxyRaw(proxyPort: proxyPort, absoluteURI: "http://local.test/api/thing", host: "local.test", group: group)
	guard let statusLine = raw.split(separator: "\r\n", maxSplits: 1).first else {
		Issue.record("proxy returned an empty response")
		return
	}
	#expect(statusLine.contains("502"))
}

@Test func postRequestBodyIsFullyForwardedToOrigin() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }
	let (origin, originPort) = try startBodyEchoOrigin(group: group)
	defer { try? origin.close().wait() }

	let mapping = Mapping(
		from: "http://local.test/api/*",
		to: "http://127.0.0.1:\(originPort)/api/*",
		enabled: true
	)
	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	let requestBody = "hello=world&foo=bar&some=more-data-to-exercise-buffering"
	let echoed = try postThroughProxy(proxyPort: proxyPort, absoluteURI: "http://local.test/api/thing", host: "local.test", body: requestBody, group: group)
	#expect(echoed == requestBody)
}

@Test func plainHTTPRequestIsRewrittenAndForwarded() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }
	let (origin, originPort) = try startEchoOrigin(group: group)
	defer { try? origin.close().wait() }

	// Map a fake local host to the real origin on 127.0.0.1:<originPort>.
	let mapping = Mapping(
		from: "http://local.test/api/*",
		to: "http://127.0.0.1:\(originPort)/api/*",
		enabled: true
	)
	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	// Send a proxy-style absolute-URI request through the proxy.
	let body = try fetchThroughProxy(proxyPort: proxyPort, absoluteURI: "http://local.test/api/thing?x=1", host: "local.test", group: group)
	#expect(body == "/api/thing?x=1|127.0.0.1:\(originPort)")
}

@Test func secondRequestBodyOnKeepAliveConnectionReachesOrigin() throws {
	let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
	defer { try? group.syncShutdownGracefully() }
	let (origin, originPort) = try startBodyEchoOrigin(group: group)
	defer { try? origin.close().wait() }

	let mapping = Mapping(
		from: "http://local.test/api/*",
		to: "http://127.0.0.1:\(originPort)/api/*",
		enabled: true
	)
	let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
	let proxyPort = try server.start()
	defer { try? server.stop() }

	// Request 1 has no body and does NOT ask for Connection: close, so the
	// inbound socket stays open (keep-alive) for request 2. Request 2 carries
	// a chunked body to a mapped target: this is the case that hangs forever
	// if `self.upstream` is left pointing at request 1's already-closed
	// upstream channel instead of being reset for the new request.
	let secondBody = "second-request-chunked-body-must-reach-origin-intact"
	let (firstResponse, secondResponse) = try sendTwoRequestsOnKeepAliveConnection(
		proxyPort: proxyPort,
		host: "local.test",
		secondBody: secondBody,
		group: group
	)

	#expect(firstResponse.contains(" 200 "))
	#expect(secondResponse.contains(" 200 "))
	#expect(secondResponse.hasSuffix(secondBody))
}

// A test-runner watchdog: if the proxy never closes the connection (e.g. a
// dropped .end hangs the request), fail after `timeout` instead of blocking
// the suite forever.
private struct TestTimeoutError: Error {}

// Sends a raw request through the proxy and returns the full raw response
// (status line + headers + body), waiting for the server to close the
// connection (all test requests send "Connection: close").
private func sendRawRequest(proxyPort: Int, raw: String, group: EventLoopGroup, timeout: TimeAmount = .seconds(5)) throws -> String {
	final class Collector: ChannelInboundHandler {
		typealias InboundIn = ByteBuffer
		let promise: EventLoopPromise<String>
		var acc = ""
		init(_ p: EventLoopPromise<String>) { promise = p }
		func channelRead(context: ChannelHandlerContext, data: NIOAny) {
			var b = unwrapInboundIn(data)
			acc += b.readString(length: b.readableBytes) ?? ""
		}
		func channelInactive(context: ChannelHandlerContext) { promise.succeed(acc) }
	}
	let promise = group.next().makePromise(of: String.self)
	let channel = try ClientBootstrap(group: group)
		.channelInitializer { $0.pipeline.addHandler(Collector(promise)) }
		.connect(host: "127.0.0.1", port: proxyPort).wait()
	let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
		promise.fail(TestTimeoutError())
	}
	promise.futureResult.whenComplete { _ in timeoutTask.cancel() }
	defer { try? channel.close().wait() }
	var buf = channel.allocator.buffer(capacity: raw.utf8.count)
	buf.writeString(raw)
	try channel.writeAndFlush(buf).wait()
	return try promise.futureResult.wait()
}

private func fetchThroughProxy(proxyPort: Int, absoluteURI: String, host: String, group: EventLoopGroup) throws -> String {
	let full = try fetchThroughProxyRaw(proxyPort: proxyPort, absoluteURI: absoluteURI, host: host, group: group)
	// Return only the response body (after the blank line).
	guard let range = full.range(of: "\r\n\r\n") else { return full }
	return String(full[range.upperBound...])
}

// Like fetchThroughProxy but returns the full raw response, including the
// status line, so callers can assert on the status code.
private func fetchThroughProxyRaw(proxyPort: Int, absoluteURI: String, host: String, group: EventLoopGroup) throws -> String {
	let raw = "GET \(absoluteURI) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
	return try sendRawRequest(proxyPort: proxyPort, raw: raw, group: group)
}

// Sends the body chunk-encoded (Transfer-Encoding: chunked) rather than with
// a Content-Length. A Content-Length body would already be fully readable by
// the origin from the .body writes alone; chunked framing only becomes
// complete once the terminating "0\r\n\r\n" chunk is written, which only
// happens if the proxy actually forwards the request's .end signal.
private func postThroughProxy(proxyPort: Int, absoluteURI: String, host: String, body: String, group: EventLoopGroup) throws -> String {
	let chunkSize = String(body.utf8.count, radix: 16)
	let raw = "POST \(absoluteURI) HTTP/1.1\r\nHost: \(host)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(chunkSize)\r\n\(body)\r\n0\r\n\r\n"
	let full = try sendRawRequest(proxyPort: proxyPort, raw: raw, group: group)
	guard let range = full.range(of: "\r\n\r\n") else { return full }
	return String(full[range.upperBound...])
}

// Given accumulated bytes read so far from a socket, returns the first
// complete HTTP/1.1 response (status line + headers + Content-Length body)
// plus whatever bytes follow it, or nil if the response isn't complete yet.
// All responses in this test file are generated by our own echo origins,
// which always send Content-Length (never chunked), so that's the only
// framing this needs to understand.
private func extractCompleteHTTPResponse(_ text: String) -> (response: String, remainder: String)? {
	guard let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
	let headerPart = text[text.startIndex..<headerEnd.lowerBound]
	var contentLength = 0
	for line in headerPart.split(separator: "\r\n") {
		if line.lowercased().hasPrefix("content-length:"), let colon = line.firstIndex(of: ":") {
			let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			contentLength = Int(value) ?? 0
		}
	}
	let bodyStart = headerEnd.upperBound
	guard text.distance(from: bodyStart, to: text.endIndex) >= contentLength else { return nil }
	let bodyEnd = text.index(bodyStart, offsetBy: contentLength)
	return (String(text[text.startIndex..<bodyEnd]), String(text[bodyEnd...]))
}

// Collects bytes from a single kept-open socket, resolves `response1Promise`
// once the first full response arrives, immediately writes the second raw
// request onto the SAME channel (proving keep-alive reuse), then resolves
// `response2Promise` once the second full response arrives.
private final class KeepAliveTwoResponseCollector: ChannelInboundHandler {
	typealias InboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	private var acc = ""
	private var awaitingSecondRequest = true
	private let secondRequestRaw: String
	private let response1Promise: EventLoopPromise<String>
	private let response2Promise: EventLoopPromise<String>

	init(secondRequestRaw: String, response1Promise: EventLoopPromise<String>, response2Promise: EventLoopPromise<String>) {
		self.secondRequestRaw = secondRequestRaw
		self.response1Promise = response1Promise
		self.response2Promise = response2Promise
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		var buffer = unwrapInboundIn(data)
		acc += buffer.readString(length: buffer.readableBytes) ?? ""
		guard let (response, remainder) = extractCompleteHTTPResponse(acc) else { return }
		acc = remainder
		if awaitingSecondRequest {
			awaitingSecondRequest = false
			response1Promise.succeed(response)
			var out = context.channel.allocator.buffer(capacity: secondRequestRaw.utf8.count)
			out.writeString(secondRequestRaw)
			context.writeAndFlush(wrapOutboundOut(out), promise: nil)
		} else {
			response2Promise.succeed(response)
		}
	}
}

// Opens ONE connection to the proxy, sends `firstRequestRaw`, waits for its
// complete response, then sends a chunked POST carrying `secondBody` on the
// SAME connection and waits for its complete response — exercising keep-alive
// reuse end to end. Bounded by `timeout` so a hang (the Bug A symptom) fails
// the test instead of blocking the suite.
private func sendTwoRequestsOnKeepAliveConnection(proxyPort: Int, host: String, secondBody: String, group: EventLoopGroup, timeout: TimeAmount = .seconds(5)) throws -> (first: String, second: String) {
	let firstRequestRaw = "GET http://\(host)/api/thing HTTP/1.1\r\nHost: \(host)\r\n\r\n"
	let chunkSize = String(secondBody.utf8.count, radix: 16)
	let secondRequestRaw = "POST http://\(host)/api/thing HTTP/1.1\r\nHost: \(host)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n\(chunkSize)\r\n\(secondBody)\r\n0\r\n\r\n"

	let response1Promise = group.next().makePromise(of: String.self)
	let response2Promise = group.next().makePromise(of: String.self)

	let channel = try ClientBootstrap(group: group)
		.channelInitializer { channel in
			channel.pipeline.addHandler(KeepAliveTwoResponseCollector(secondRequestRaw: secondRequestRaw, response1Promise: response1Promise, response2Promise: response2Promise))
		}
		.connect(host: "127.0.0.1", port: proxyPort).wait()
	defer { try? channel.close().wait() }

	// A promise that's already fulfilled silently ignores a later fail (NIO's
	// `_setValue` is a no-op once `_value` is set), so failing both here on
	// timeout is safe even though response1 will normally have already
	// succeeded well before this fires.
	let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
		response1Promise.fail(TestTimeoutError())
		response2Promise.fail(TestTimeoutError())
	}
	response2Promise.futureResult.whenComplete { _ in timeoutTask.cancel() }

	var buf = channel.allocator.buffer(capacity: firstRequestRaw.utf8.count)
	buf.writeString(firstRequestRaw)
	try channel.writeAndFlush(buf).wait()

	let first = try response1Promise.futureResult.wait()
	let second = try response2Promise.futureResult.wait()
	return (first, second)
}

// MARK: - Fallback-on-404 mode

// Origin stub that answers every request with a fixed status + body, so a test
// can stand in for a "local" origin (404) and a "remote" origin (200).
private final class StatusOriginHandler: ChannelInboundHandler {
	typealias InboundIn = HTTPServerRequestPart
	typealias OutboundOut = HTTPServerResponsePart
	private let status: HTTPResponseStatus
	private let body: String
	private let contentType: String?
	init(status: HTTPResponseStatus, body: String, contentType: String? = nil) {
		self.status = status
		self.body = body
		self.contentType = contentType
	}
	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		guard case .end = unwrapInboundIn(data) else { return }
		var headers = HTTPHeaders()
		headers.add(name: "Content-Length", value: String(body.utf8.count))
		if let contentType { headers.add(name: "Content-Type", value: contentType) }
		context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
		var buf = context.channel.allocator.buffer(capacity: body.utf8.count)
		buf.writeString(body)
		context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
		context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
	}
}

private func startStatusOrigin(status: HTTPResponseStatus, body: String, contentType: String? = nil, group: EventLoopGroup) throws -> (channel: Channel, port: Int) {
	let channel = try ServerBootstrap(group: group)
		.serverChannelOption(ChannelOptions.backlog, value: 16)
		.childChannelInitializer { channel in
			channel.pipeline.configureHTTPServerPipeline().flatMap {
				channel.pipeline.addHandler(StatusOriginHandler(status: status, body: body, contentType: contentType))
			}
		}
		.bind(host: "127.0.0.1", port: 0).wait()
	return (channel, channel.localAddress!.port!)
}

// Pure unit tests for the miss-detection rule (fast; not in the serialized suite).
@Test func fallbackMissOn404() {
	#expect(ProxyGlueHandler.isFallbackMiss(statusCode: 404, contentType: "image/jpeg", requestPath: "/a/x.jpg"))
}
@Test func fallbackMissOn200WithErrorBodyForAsset() {
	// The reported case: 200 + text/plain (S3 NoSuchKey) for a .jpg request.
	#expect(ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "text/plain; charset=utf-8", requestPath: "/tachyon/sites/3/x.jpg"))
	#expect(ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "application/xml", requestPath: "/a/x.png"))
}
@Test func fallbackMissOn200WithNoContentTypeForImage() {
	// Second reported case: 200 with NO Content-Type header for a .png request.
	#expect(ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: nil, requestPath: "/tachyon/sites/3/2026/05/x.png"))
	#expect(ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "", requestPath: "/a/x.png"))
}
@Test func realImageIsNotAMiss() {
	#expect(!ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "image/jpeg", requestPath: "/a/x.jpg"))
}
@Test func legitTextDocumentIsNotSecondGuessed() {
	// A request that genuinely asked for a JSON/HTML doc must not be treated as
	// a miss just because it came back as JSON/HTML.
	#expect(!ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "application/json", requestPath: "/api/data.json"))
	#expect(!ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "text/html", requestPath: "/page.html"))
}
@Test func legitCSSAndJSAreNotMisses() {
	#expect(!ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "text/css", requestPath: "/a/style.css"))
	#expect(!ProxyGlueHandler.isFallbackMiss(statusCode: 200, contentType: "application/javascript", requestPath: "/a/app.js"))
}

// These integration tests each stand up real NIO servers + a proxy and block
// the test thread on `.wait()`. Grouped into a `.serialized` suite so they run
// one-at-a-time rather than piling several simultaneous thread-blocking tests
// onto swift-testing's parallel pool (enough concurrent blockers stall the run).
@Suite(.serialized)
struct FallbackModeTests {
	@Test func servesRemoteWhenLocalReturns404() throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let (local, localPort) = try startStatusOrigin(status: .notFound, body: "local-not-found", group: group)
		defer { try? local.close().wait() }
		let (remote, remotePort) = try startStatusOrigin(status: .ok, body: "REMOTE-IMAGE-BYTES", group: group)
		defer { try? remote.close().wait() }

		let mapping = Mapping(
			from: "http://127.0.0.1:\(localPort)/assets/*",
			to: "http://127.0.0.1:\(remotePort)/assets/*",
			enabled: true,
			mode: .fallbackOnNotFound
		)
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let body = try fetchThroughProxy(proxyPort: proxyPort,
			absoluteURI: "http://127.0.0.1:\(localPort)/assets/photo.jpg",
			host: "127.0.0.1:\(localPort)", group: group)
		// Local 404 → proxy refetched from the remote target; client gets remote body.
		#expect(body == "REMOTE-IMAGE-BYTES")
	}

	@Test func servesLocalWhenLocalReturns200() throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let (local, localPort) = try startStatusOrigin(status: .ok, body: "LOCAL-IMAGE-BYTES", contentType: "image/jpeg", group: group)
		defer { try? local.close().wait() }
		let (remote, remotePort) = try startStatusOrigin(status: .ok, body: "REMOTE-IMAGE-BYTES", contentType: "image/jpeg", group: group)
		defer { try? remote.close().wait() }

		let mapping = Mapping(
			from: "http://127.0.0.1:\(localPort)/assets/*",
			to: "http://127.0.0.1:\(remotePort)/assets/*",
			enabled: true,
			mode: .fallbackOnNotFound
		)
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let body = try fetchThroughProxy(proxyPort: proxyPort,
			absoluteURI: "http://127.0.0.1:\(localPort)/assets/photo.jpg",
			host: "127.0.0.1:\(localPort)", group: group)
		// Local served a real image (200 image/jpeg) → no fallback.
		#expect(body == "LOCAL-IMAGE-BYTES")
	}

	@Test func servesRemoteWhenLocalReturns200WithErrorBody() throws {
		// The reported case: the local origin answers a missing image with 200 +
		// a text/plain S3-style error body instead of a real 404.
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let (local, localPort) = try startStatusOrigin(status: .ok,
			body: #"{"Code":"NoSuchKey"}"#, contentType: "text/plain; charset=utf-8", group: group)
		defer { try? local.close().wait() }
		let (remote, remotePort) = try startStatusOrigin(status: .ok, body: "REMOTE-IMAGE-BYTES", contentType: "image/jpeg", group: group)
		defer { try? remote.close().wait() }

		let mapping = Mapping(
			from: "http://127.0.0.1:\(localPort)/assets/*",
			to: "http://127.0.0.1:\(remotePort)/assets/*",
			enabled: true,
			mode: .fallbackOnNotFound
		)
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let body = try fetchThroughProxy(proxyPort: proxyPort,
			absoluteURI: "http://127.0.0.1:\(localPort)/assets/photo.jpg",
			host: "127.0.0.1:\(localPort)", group: group)
		// 200 + error body for a .jpg → treated as missing → served from remote.
		#expect(body == "REMOTE-IMAGE-BYTES")
	}

	@Test func fallbackResponseIsMarkedNoStore() throws {
		// A fallback (remote-after-miss) response must not be cached by the
		// browser, so it re-checks local next time.
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let (local, localPort) = try startStatusOrigin(status: .notFound, body: "nope", group: group)
		defer { try? local.close().wait() }
		let (remote, remotePort) = try startStatusOrigin(status: .ok, body: "REMOTE-IMAGE-BYTES", contentType: "image/jpeg", group: group)
		defer { try? remote.close().wait() }

		let mapping = Mapping(
			from: "http://127.0.0.1:\(localPort)/assets/*",
			to: "http://127.0.0.1:\(remotePort)/assets/*",
			enabled: true,
			mode: .fallbackOnNotFound
		)
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let raw = try fetchThroughProxyRaw(proxyPort: proxyPort,
			absoluteURI: "http://127.0.0.1:\(localPort)/assets/photo.jpg",
			host: "127.0.0.1:\(localPort)", group: group)
		#expect(raw.lowercased().contains("cache-control: no-store"))
		#expect(raw.contains("REMOTE-IMAGE-BYTES"))
	}

	@Test func servesRemoteWhenLocalReturns200WithNoContentType() throws {
		// Second reported case: local answers a missing .png with 200 and NO
		// Content-Type header at all.
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let (local, localPort) = try startStatusOrigin(status: .ok, body: "err", group: group) // no contentType
		defer { try? local.close().wait() }
		let (remote, remotePort) = try startStatusOrigin(status: .ok, body: "REMOTE-PNG-BYTES", contentType: "image/png", group: group)
		defer { try? remote.close().wait() }

		let mapping = Mapping(
			from: "http://127.0.0.1:\(localPort)/assets/*",
			to: "http://127.0.0.1:\(remotePort)/assets/*",
			enabled: true,
			mode: .fallbackOnNotFound
		)
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let body = try fetchThroughProxy(proxyPort: proxyPort,
			absoluteURI: "http://127.0.0.1:\(localPort)/assets/pic.png",
			host: "127.0.0.1:\(localPort)", group: group)
		#expect(body == "REMOTE-PNG-BYTES")
	}

	@Test func rewriteModeAlwaysServesRemoteEvenWhenLocalWouldSucceed() throws {
		let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
		defer { try? group.syncShutdownGracefully() }
		let (remote, remotePort) = try startStatusOrigin(status: .ok, body: "REMOTE-IMAGE-BYTES", group: group)
		defer { try? remote.close().wait() }

		// Rewrite mode: the "local" host is never contacted — everything goes remote.
		let mapping = Mapping(
			from: "http://local.invalid/assets/*",
			to: "http://127.0.0.1:\(remotePort)/assets/*",
			enabled: true,
			mode: .rewrite
		)
		let server = ProxyServer(port: 0, engineProvider: { MappingEngine(mappings: [mapping]) }, ca: nil)
		let proxyPort = try server.start()
		defer { try? server.stop() }

		let body = try fetchThroughProxy(proxyPort: proxyPort,
			absoluteURI: "http://local.invalid/assets/photo.jpg",
			host: "local.invalid", group: group)
		#expect(body == "REMOTE-IMAGE-BYTES")
	}
}
