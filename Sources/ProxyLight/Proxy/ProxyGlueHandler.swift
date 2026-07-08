import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import Foundation

// Forwards a single proxied HTTP request to an upstream and streams the reply back.
// Conforms to RemovableChannelHandler so ConnectHandler can remove an installed
// instance by reference if a later CONNECT reconfigures the pipeline (see
// ConnectHandler.teardownHTTPServerPipeline).
final class ProxyGlueHandler: ChannelInboundHandler, RemovableChannelHandler {
	typealias InboundIn = HTTPServerRequestPart
	typealias OutboundOut = HTTPServerResponsePart

	private let engineProvider: () -> MappingEngine
	private var upstream: Channel?
	private var pendingBody: [ByteBuffer] = []
	private var pendingEnd = false
	private let inboundScheme: String
	private let inboundHostOverride: String?
	// Tracks whether the inbound connection is still alive. A keep-alive
	// connection can disconnect while a new upstream connect is in flight
	// (i.e. before the connect-success handler below has run and assigned
	// `self.upstream`); this flag lets that handler notice and close the
	// now-orphaned upstream channel instead of leaking the socket.
	private var inboundActive = true

	init(engineProvider: @escaping () -> MappingEngine, scheme: String = "http", hostOverride: String? = nil) {
		self.engineProvider = engineProvider
		self.inboundScheme = scheme
		self.inboundHostOverride = hostOverride
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch unwrapInboundIn(data) {
		case .head(let head):
			handleHead(context: context, head: head)
		case .body(let buffer):
			forwardBody(buffer)
		case .end:
			forwardEnd()
		}
	}

	// The inbound client disconnected (possibly mid-request). The upstream
	// channel is single-use and nothing else will ever read its response, so
	// close it rather than leaking the socket.
	func channelInactive(context: ChannelHandlerContext) {
		inboundActive = false
		upstream?.close(promise: nil)
		context.fireChannelInactive()
	}

	private func handleHead(context: ChannelHandlerContext, head: HTTPRequestHead) {
		// This is a fresh request on a possibly keep-alive connection: reset
		// per-request state before opening the new upstream. Without this,
		// `self.upstream` would still point at the PREVIOUS request's (already
		// closed) upstream channel until the new connect completes, so
		// forwardBody/forwardEnd would wrongly take the "write directly"
		// branch and write this request's body into a dead channel instead of
		// buffering it — hanging the request forever. handleHead runs on
		// `.head`, strictly before this request's own `.body`/`.end`, so this
		// reset can never drop data belonging to the current request.
		upstream = nil
		pendingBody = []
		pendingEnd = false

		let (host, port, path) = Self.resolveTarget(head: head, scheme: inboundScheme, hostOverride: inboundHostOverride)
		let match = engineProvider().rewrite(scheme: inboundScheme, host: host, port: port, uri: path)
		// The client's own keep-alive intent decides whether we close the
		// inbound connection once this response finishes.
		let closeAfterResponse = !head.isKeepAlive
		let inbound = context.channel
		let eventLoop = context.eventLoop
		// Fallback only makes sense for safe, bodyless requests we can safely
		// re-issue against the remote; anything else routes as a plain rewrite.
		let isSafeMethod = head.method == .GET || head.method == .HEAD

		if let r = match, r.mode == .fallbackOnNotFound, isSafeMethod {
			// Local-first: serve the original origin; only if it answers 404 do
			// we re-issue the request against the remote target.
			let localHead = makeRequestHead(head: head, uri: path, host: host, port: port, scheme: inboundScheme)
			let remoteHead = makeRequestHead(head: head, uri: r.uri, host: r.host, port: r.port, scheme: r.scheme)
			let requestPath = path
			let relay = FallbackRelay(
				inbound: inbound,
				closeAfterResponse: closeAfterResponse,
				shouldFallback: { responseHead in
					Self.isFallbackMiss(
						statusCode: Int(responseHead.status.code),
						contentType: responseHead.headers.first(name: "Content-Type"),
						requestPath: requestPath)
				},
				onFallback: { [weak self] in
					guard let self, self.inboundActive else { return }
					// Local didn't have it — refetch from the remote target. A
					// fallback request is a complete GET/HEAD (no body): re-send
					// head + end.
					self.upstream = nil
					self.pendingBody = []
					self.pendingEnd = true
					self.openUpstream(inbound: inbound, eventLoop: eventLoop,
						scheme: r.scheme, host: r.host, port: r.port, head: remoteHead,
						responder: ResponseRelay(inbound: inbound, closeAfterResponse: closeAfterResponse, noStore: true))
				})
			openUpstream(inbound: inbound, eventLoop: eventLoop,
				scheme: inboundScheme, host: host, port: port, head: localHead, responder: relay)
		} else {
			// Rewrite mode, no match, or an unsafe method: forward to the target
			// unconditionally (target is the remote on a match, else the origin).
			let target = match.map { ($0.scheme, $0.host, $0.port, $0.uri) } ?? (inboundScheme, host, port, path)
			let newHead = makeRequestHead(head: head, uri: target.3, host: target.1, port: target.2, scheme: target.0)
			openUpstream(inbound: inbound, eventLoop: eventLoop,
				scheme: target.0, host: target.1, port: target.2, head: newHead,
				responder: ResponseRelay(inbound: inbound, closeAfterResponse: closeAfterResponse))
		}
	}

	private func makeRequestHead(head: HTTPRequestHead, uri: String, host: String, port: Int, scheme: String) -> HTTPRequestHead {
		var newHead = HTTPRequestHead(version: .http1_1, method: head.method, uri: uri)
		newHead.headers = head.headers
		newHead.headers.replaceOrAdd(name: "Host", value: hostHeader(host: host, port: port, scheme: scheme))
		newHead.headers.remove(name: "Proxy-Connection")
		return newHead
	}

	private func openUpstream(inbound: Channel, eventLoop: EventLoop, scheme: String, host: String, port: Int, head: HTTPRequestHead, responder: ChannelHandler) {
		let useTLS = scheme == "https"
		let bootstrap = ClientBootstrap(group: eventLoop)
			.channelInitializer { channel in
				let addTLS: EventLoopFuture<Void>
				if useTLS {
					do {
						let tls = try NIOSSLClientContextCache.context()
						let ssl = try NIOSSLClientHandler(context: tls, serverHostname: host)
						addTLS = channel.pipeline.addHandler(ssl)
					} catch {
						return channel.eventLoop.makeFailedFuture(error)
					}
				} else {
					addTLS = channel.eventLoop.makeSucceededVoidFuture()
				}
				return addTLS.flatMap {
					channel.pipeline.addHTTPClientHandlers().flatMap {
						channel.pipeline.addHandler(responder)
					}
				}
			}
		bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
			switch result {
			case .success(let channel):
				// The inbound client disconnected while this connect was in
				// flight (self nil after teardown, or inboundActive false if
				// channelInactive ran first). Close the orphaned channel rather
				// than leaking it, and don't write this request into it.
				guard let self, self.inboundActive else {
					channel.close(promise: nil)
					return
				}
				self.upstream = channel
				channel.write(HTTPClientRequestPart.head(head), promise: nil)
				for buf in self.pendingBody {
					channel.write(HTTPClientRequestPart.body(.byteBuffer(buf)), promise: nil)
				}
				self.pendingBody = []
				if self.pendingEnd {
					channel.write(HTTPClientRequestPart.end(nil), promise: nil)
					self.pendingEnd = false
				}
				channel.flush()
			case .failure:
				Self.sendError(inbound, status: .badGateway, message: "Upstream connection failed")
			}
		}
	}

	private func forwardBody(_ buffer: ByteBuffer) {
		if let upstream {
			upstream.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
		} else {
			pendingBody.append(buffer)
		}
	}

	private func forwardEnd() {
		if let upstream {
			upstream.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
		} else {
			pendingEnd = true
		}
	}

	// MARK: helpers

	static func resolveTarget(head: HTTPRequestHead, scheme: String, hostOverride: String?) -> (host: String, port: Int, path: String) {
		// Absolute-form (proxy) URI: "http://host:port/path". Origin-form: "/path" + Host header.
		if let comps = URLComponents(string: head.uri), let host = comps.host {
			let port = comps.port ?? (comps.scheme == "https" ? 443 : 80)
			let path = (comps.path.isEmpty ? "/" : comps.path) + (comps.query.map { "?\($0)" } ?? "")
			return (host, port, path)
		}
		let hostHeader = hostOverride ?? head.headers.first(name: "Host") ?? ""
		let (h, p) = Self.splitHostPort(hostHeader, defaultPort: scheme == "https" ? 443 : 80)
		return (h, p, head.uri)
	}

	private func hostHeader(host: String, port: Int, scheme: String) -> String {
		let defaultPort = scheme == "https" ? 443 : 80
		return port == defaultPort ? host : "\(host):\(port)"
	}

	// Decides whether a fallback mapping's LOCAL response counts as "missing"
	// (so the proxy should refetch from the remote target). A real 404 always
	// counts. Some origins — e.g. an S3-backed image proxy — instead answer a
	// missing asset with 200 and an error body; treat a generic error/document
	// Content-Type (text/plain, text/html, JSON, XML) as a miss too, UNLESS the
	// request itself asked for such a document, so a legitimately-served
	// .json/.html/.xml/.txt file isn't second-guessed.
	static func isFallbackMiss(statusCode: Int, contentType: String?, requestPath: String) -> Bool {
		if statusCode == 404 { return true }
		let essence = (contentType?.split(separator: ";").first)
			.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
		let ext = pathExtension(requestPath)

		// If the requested file has a well-known content-type family, the local
		// response is a "hit" only when it actually matches that family. Anything
		// else — the wrong type, or a MISSING Content-Type — means the origin
		// didn't really serve the asset (some origins answer a missing file with
		// 200 + an error body, sometimes with no Content-Type at all).
		if let expected = expectedContentTypePrefix(forExtension: ext) {
			return !essence.hasPrefix(expected)
		}

		// Unknown extension: never second-guess a genuinely-requested document,
		// but still treat a generic error-body content type as a miss.
		let textDocExtensions: Set<String> = ["json", "xml", "txt", "text", "html", "htm"]
		if textDocExtensions.contains(ext) { return false }
		let errorTypes: Set<String> = [
			"text/plain", "text/html", "application/json", "text/json",
			"application/xml", "text/xml", "application/problem+json",
		]
		return errorTypes.contains(essence)
	}

	// The Content-Type family a successful response for this file extension
	// should have, or nil if the extension isn't a recognized binary asset.
	static func expectedContentTypePrefix(forExtension ext: String) -> String? {
		switch ext {
		case "jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "ico", "bmp", "tif", "tiff", "heic", "heif":
			return "image/"
		case "mp4", "webm", "mov", "m4v", "ogv":
			return "video/"
		case "mp3", "wav", "ogg", "oga", "m4a", "aac", "flac":
			return "audio/"
		case "css":
			return "text/css"
		default:
			return nil
		}
	}

	// Lowercased file extension of a request path (query stripped), or "" if none.
	static func pathExtension(_ path: String) -> String {
		let noQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
		let segment = noQuery.split(separator: "/").last.map(String.init) ?? noQuery
		guard let dot = segment.lastIndex(of: "."), dot != segment.startIndex else { return "" }
		return String(segment[segment.index(after: dot)...]).lowercased()
	}

	static func splitHostPort(_ value: String, defaultPort: Int) -> (String, Int) {
		guard let idx = value.lastIndex(of: ":"), let port = Int(value[value.index(after: idx)...]) else {
			return (value, defaultPort)
		}
		return (String(value[value.startIndex..<idx]), port)
	}

	static func sendError(_ channel: Channel, status: HTTPResponseStatus, message: String) {
		var headers = HTTPHeaders()
		headers.add(name: "Content-Length", value: String(message.utf8.count))
		headers.add(name: "Connection", value: "close")
		channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)), promise: nil)
		var buf = channel.allocator.buffer(capacity: message.utf8.count)
		buf.writeString(message)
		channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
		channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
			channel.close(promise: nil)
		}
	}
}

// Streams upstream HTTPClientResponsePart back to the inbound client as HTTPServerResponsePart.
final class ResponseRelay: ChannelInboundHandler {
	typealias InboundIn = HTTPClientResponsePart
	private let inbound: Channel
	private let closeAfterResponse: Bool
	// Set once the response .end has been relayed to the inbound client. This
	// upstream channel is single-use (one request/response), so channelInactive
	// firing afterwards is the expected, harmless teardown of a channel we're
	// about to close ourselves — not a failure the inbound client needs to hear
	// about.
	private var completed = false
	// When true, force `Cache-Control: no-store` on the relayed response. Used
	// for fallback (remote-after-local-miss) responses so the browser doesn't
	// cache the remote copy and always re-requests through the proxy — that way
	// the local origin is re-checked each time and picks up an asset once it
	// exists locally, instead of serving a stale cached fallback.
	private let noStore: Bool
	init(inbound: Channel, closeAfterResponse: Bool, noStore: Bool = false) {
		self.inbound = inbound
		self.closeAfterResponse = closeAfterResponse
		self.noStore = noStore
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch unwrapInboundIn(data) {
		case .head(let head):
			var headers = head.headers
			if noStore {
				headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
				headers.remove(name: "Expires")
				headers.remove(name: "Pragma")
			}
			inbound.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: head.status, headers: headers)), promise: nil)
		case .body(let buffer):
			inbound.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
		case .end(let trailers):
			completed = true
			let done = inbound.writeAndFlush(HTTPServerResponsePart.end(trailers))
			if closeAfterResponse {
				done.whenComplete { [inbound] _ in inbound.close(promise: nil) }
			}
			// This upstream connection served exactly one request; close it now
			// that the response has been relayed instead of leaking the socket.
			context.close(promise: nil)
		}
	}

	func channelInactive(context: ChannelHandlerContext) {
		// If the response already completed normally, this is just the upstream
		// channel we closed ourselves tearing down — leave the (possibly
		// keep-alive, possibly already reused for another request) inbound
		// connection alone. Only an upstream that died mid-response should
		// force-close inbound to signal failure to the client.
		guard !completed else { return }
		inbound.close(promise: nil)
	}
}

// For a fallback-on-404 mapping: relays the LOCAL origin's response, but if that
// response is 404, discards it and invokes `onNotFound` so the handler can
// re-issue the request against the remote target instead. The 404 is never
// shown to the client.
final class FallbackRelay: ChannelInboundHandler {
	typealias InboundIn = HTTPClientResponsePart
	private let inbound: Channel
	private let closeAfterResponse: Bool
	private let shouldFallback: (HTTPResponseHead) -> Bool
	private let onFallback: () -> Void
	private var decided = false
	private var forwarding = false
	private var completed = false

	init(inbound: Channel, closeAfterResponse: Bool,
		shouldFallback: @escaping (HTTPResponseHead) -> Bool, onFallback: @escaping () -> Void) {
		self.inbound = inbound
		self.closeAfterResponse = closeAfterResponse
		self.shouldFallback = shouldFallback
		self.onFallback = onFallback
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch unwrapInboundIn(data) {
		case .head(let head):
			guard !decided else { break }
			decided = true
			if shouldFallback(head) {
				// Local origin doesn't have it: close this attempt and hand off
				// to the remote refetch.
				context.close(promise: nil)
				onFallback()
			} else {
				forwarding = true
				inbound.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: head.status, headers: head.headers)), promise: nil)
			}
		case .body(let buffer):
			if forwarding {
				inbound.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
			}
		case .end(let trailers):
			if forwarding {
				completed = true
				let done = inbound.writeAndFlush(HTTPServerResponsePart.end(trailers))
				if closeAfterResponse {
					done.whenComplete { [inbound] _ in inbound.close(promise: nil) }
				}
			}
			context.close(promise: nil)
		}
	}

	func channelInactive(context: ChannelHandlerContext) {
		// completed: local response fully relayed. decided && !forwarding: handed
		// off to the remote refetch (404 path), which now owns inbound. Either
		// way, leave inbound alone. Otherwise the local upstream died before a
		// response could be relayed — close inbound to signal failure.
		if completed || (decided && !forwarding) { return }
		inbound.close(promise: nil)
	}
}

// Shared client TLS context (verifies real upstream certificates).
enum NIOSSLClientContextCache {
	private static let shared: NIOSSLContext = {
		var config = TLSConfiguration.makeClientConfiguration()
		config.applicationProtocols = ["http/1.1"]
		return try! NIOSSLContext(configuration: config)
	}()
	static func context() throws -> NIOSSLContext { shared }
}
