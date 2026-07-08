import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import Foundation

// Installed as the first handler after the HTTP server codec stack for every
// proxied connection. Dispatches CONNECT requests to either a MITM TLS
// pipeline (mapped https hosts) or a blind byte tunnel (everything else, so
// unmapped-host traffic is never decrypted); non-CONNECT requests are
// handled as plain HTTP via ProxyGlueHandler (Task 6).
final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
	typealias InboundIn = HTTPServerRequestPart
	typealias OutboundOut = HTTPServerResponsePart

	private let engineProvider: () -> MappingEngine
	private let ca: CertificateAuthority?
	// Captured at pipeline-install time (see HTTPServerCodec.install below) so
	// they can be torn down by reference before a CONNECT reconfigures the
	// channel. `configureHTTPServerPipeline`'s handlers are added under names
	// that aren't part of its public contract and aren't stable across NIO
	// versions, so removing them by string name would be fragile. Holding the
	// actual instances and removing them via `syncOperations.removeHandler(_:)`
	// is version-proof.
	private let httpServerCodecHandlers: [RemovableChannelHandler]
	private var glueInstalled = false
	// The ProxyGlueHandler instance installed by installPlainGlue, if any, kept
	// so a CONNECT arriving later on this same keep-alive connection (see
	// channelRead below) can remove it by reference before reconfiguring the
	// pipeline for MITM/tunnel.
	private var installedGlueHandler: ProxyGlueHandler?

	init(engineProvider: @escaping () -> MappingEngine, ca: CertificateAuthority?, httpServerCodecHandlers: [RemovableChannelHandler]) {
		self.engineProvider = engineProvider
		self.ca = ca
		self.httpServerCodecHandlers = httpServerCodecHandlers
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		// A CONNECT can arrive as ANY request on a keep-alive connection, not
		// just the first: a client may send a plain proxied GET (installing
		// plain-HTTP glue below), then reuse the same connection for a CONNECT
		// to tunnel/MITM a different host. So every `.head` is inspected for
		// CONNECT regardless of `glueInstalled`; only `.body`/`.end` — which
		// can only belong to an in-flight plain request already dispatched to
		// glue — short-circuit straight there.
		guard case .head(let head) = unwrapInboundIn(data) else {
			if glueInstalled {
				context.fireChannelRead(data)
			}
			// A body/end before any head has been dispatched can't carry a
			// meaningful request; nothing to forward it to yet.
			return
		}

		if head.method == .CONNECT {
			handleConnect(context: context, head: head)
		} else {
			installPlainGlue(context: context)
			context.fireChannelRead(data)
		}
	}

	private func handleConnect(context: ChannelHandlerContext, head: HTTPRequestHead) {
		let (host, port) = ProxyGlueHandler.splitHostPort(head.uri, defaultPort: 443)
		let mapped = engineProvider().matchesHost(scheme: "https", host: host, port: port)

		if mapped, let ca {
			startMITM(context: context, host: host, ca: ca)
		} else {
			startBlindTunnel(context: context, host: host, port: port)
		}
	}

	// MARK: MITM (mapped https host)

	private func startMITM(context: ChannelHandlerContext, host: String, ca: CertificateAuthority) {
		let channel = context.channel
		let engineProvider = self.engineProvider
		respondConnectEstablished(context: context) {
			self.teardownHTTPServerPipeline(channel: channel).whenComplete { result in
				guard case .success = result else {
					channel.close(promise: nil)
					return
				}
				Self.installMITMPipeline(channel: channel, host: host, ca: ca, engineProvider: engineProvider)
			}
		}
	}

	// Rebuilds the channel from scratch: TLS server termination, then a fresh
	// HTTP server codec stack, then a ProxyGlueHandler that rewrites the
	// decrypted inner requests and forwards them upstream over TLS.
	private static func installMITMPipeline(channel: Channel, host: String, ca: CertificateAuthority, engineProvider: @escaping () -> MappingEngine) {
		do {
			let tls = try ca.serverContext(forHost: host)
			let sslHandler = NIOSSLServerHandler(context: tls)
			channel.pipeline.addHandler(sslHandler).flatMap {
				channel.eventLoop.makeCompletedFuture(withResultOf: {
					_ = try HTTPServerCodec.install(on: channel)
				})
			}.flatMap {
				channel.pipeline.addHandler(ProxyGlueHandler(engineProvider: engineProvider, scheme: "https", hostOverride: host))
			}.whenFailure { _ in channel.close(promise: nil) }
		} catch {
			channel.close(promise: nil)
		}
	}

	// MARK: Blind tunnel (unmapped host — never decrypted)

	private func startBlindTunnel(context: ChannelHandlerContext, host: String, port: Int) {
		let inbound = context.channel

		// Connect upstream BEFORE answering 200, so a dead upstream still gets
		// a real error response instead of a tunnel to nowhere.
		ClientBootstrap(group: context.eventLoop)
			.channelInitializer { upstream in
				upstream.pipeline.addHandler(TunnelRelayHandler(peer: inbound))
			}
			.connect(host: host, port: port)
			.whenComplete { [weak self] result in
				guard let self else {
					// ConnectHandler was torn down (e.g. inbound already closed)
					// while this connect was in flight — nothing will ever use
					// this upstream channel, so close it rather than leaking it.
					if case .success(let upstream) = result {
						upstream.close(promise: nil)
					}
					return
				}
				switch result {
				case .success(let upstream):
					self.respondConnectEstablished(context: context) {
						self.teardownHTTPServerPipeline(channel: inbound).whenComplete { result in
							guard case .success = result else {
								inbound.close(promise: nil)
								upstream.close(promise: nil)
								return
							}
							_ = inbound.pipeline.addHandler(TunnelRelayHandler(peer: upstream))
						}
					}
				case .failure:
					ProxyGlueHandler.sendError(inbound, status: .badGateway, message: "CONNECT upstream failed")
				}
			}
	}

	// MARK: Shared helpers

	private func respondConnectEstablished(context: ChannelHandlerContext, then: @escaping () -> Void) {
		// The CONNECT 200 response must carry NO body framing. With neither a
		// Content-Length nor a body-less status, NIO's HTTPResponseEncoder
		// defaults an HTTP/1.1 200 to chunked transfer-encoding — and `.end`
		// then emits the empty-chunk terminator "0\r\n\r\n" INTO THE TUNNEL.
		// The client, which speaks first in TLS, sends its ClientHello and then
		// reads those 5 bytes as the server's first TLS record; "0" (0x30) is a
		// bogus record type/version, so the handshake aborts with a "protocol
		// version" alert and the tunnel dies. An explicit Content-Length: 0
		// forces fixed-length framing, so `.end` emits nothing after the header.
		var headers = HTTPHeaders()
		headers.add(name: "Content-Length", value: "0")
		let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: 200, reasonPhrase: "Connection Established"), headers: headers)
		context.write(wrapOutboundOut(.head(head)), promise: nil)
		context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
			then()
		}
	}

	private func installPlainGlue(context: ChannelHandlerContext) {
		guard !glueInstalled else { return }
		glueInstalled = true
		// ConnectHandler is always the last handler in the pipeline at this
		// point, so `.last` (the default) places ProxyGlueHandler directly
		// after it — `.after(self)` would need `ConnectHandler: Sendable`.
		let glue = ProxyGlueHandler(engineProvider: engineProvider)
		installedGlueHandler = glue
		context.pipeline.addHandler(glue).whenFailure { [weak context] _ in
			context?.close(promise: nil)
		}
	}

	// Removes this handler, the HTTP server codec handlers installed alongside
	// it, and (if a plain request on this connection installed it earlier) the
	// ProxyGlueHandler, all by reference, leaving the channel carrying raw
	// bytes — ready for either a fresh TLS+HTTP pipeline (MITM) or a raw relay
	// (blind tunnel). The glue handler is always idle at this point: it's only
	// ever reached via a `.head` that starts a new request (see channelRead),
	// so a CONNECT `.head` arriving here means the prior plain request it
	// served already ran to completion.
	private func teardownHTTPServerPipeline(channel: Channel) -> EventLoopFuture<Void> {
		var removals = httpServerCodecHandlers.map { channel.pipeline.syncOperations.removeHandler($0) }
		if let installedGlueHandler {
			removals.append(channel.pipeline.syncOperations.removeHandler(installedGlueHandler))
		}
		removals.append(channel.pipeline.syncOperations.removeHandler(self))
		return EventLoopFuture.andAllSucceed(removals, on: channel.eventLoop)
	}
}

// Relays raw bytes to a peer channel. One instance sits on each side of a
// blind CONNECT tunnel; every inbound byte is written straight to the peer
// with no HTTP interpretation, so unmapped-host traffic is never decrypted
// or parsed.
final class TunnelRelayHandler: ChannelInboundHandler {
	typealias InboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	private let peer: Channel

	init(peer: Channel) {
		self.peer = peer
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		peer.writeAndFlush(data, promise: nil)
	}

	func channelInactive(context: ChannelHandlerContext) {
		peer.close(promise: nil)
	}
}

// Guards against an unbounded request header block. `HTTPRequestDecoder` (NIO
// 2.101) has no maximum-header-size option, so without this handler a client
// could stream headers forever and grow the decoder's internal buffer
// without limit. Installed FIRST in the server pipeline — before
// `HTTPRequestDecoder` — so it sees raw bytes off the socket and can reject
// an oversized head before any of it is buffered/parsed downstream.
//
// Scope/limitation (documented deliberately, see feature-431-report.md): this
// handler only counts bytes for the FIRST request head seen on the
// connection it's installed on. Once it finds the `\r\n\r\n` end-of-headers
// terminator for that first request, it becomes a permanent pass-through —
// it forwards everything after that (the rest of that request's body, and
// any subsequent keep-alive/pipelined requests on the same connection)
// unchanged, with no further size accounting. A byte-level handler sitting
// in front of the decoder has no HTTP framing knowledge (Content-Length vs.
// chunked, trailers, etc.), so it cannot reliably tell where one request's
// body ends and the next request's headers begin in order to re-arm the
// counter per request. Each accepted TCP connection — and each MITM
// pipeline rebuilt after CONNECT/TLS termination — gets a fresh instance via
// `HTTPServerCodec.install`, so the cap still applies to the first request
// on every new connection/tunnel; only 2nd+ requests on one long-lived
// keep-alive connection fall outside it.
final class RequestHeadSizeGuard: ChannelInboundHandler, RemovableChannelHandler {
	typealias InboundIn = ByteBuffer
	typealias OutboundOut = ByteBuffer

	static let maxRequestHeadBytes = 64 * 1024

	private static let headTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // "\r\n\r\n"
	// KMP failure function for `headTerminator`, indexed by (matchLength - 1):
	// how far to fall back to `matchLength` when the next byte doesn't extend
	// the current match. Only the pattern's self-overlap (the lone leading
	// "\r") produces a non-zero fallback, at matchLength 3 ("\r\n\r").
	private static let terminatorFailure = [0, 0, 1]

	private enum State {
		case counting
		case passthrough
		case rejected
	}

	private var state: State = .counting
	private var headBytesSeen = 0
	private var matchLength = 0

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch state {
		case .passthrough:
			context.fireChannelRead(data)
		case .rejected:
			// Connection is already being torn down; drop anything further.
			break
		case .counting:
			let buffer = unwrapInboundIn(data)
			switch scanHead(buffer.readableBytesView) {
			case .terminatorFound:
				state = .passthrough
				context.fireChannelRead(data)
			case .exceeded:
				state = .rejected
				rejectOversizedHead(context: context)
			case .stillCounting:
				context.fireChannelRead(data)
			}
		}
	}

	private enum ScanResult {
		case terminatorFound
		case exceeded
		case stillCounting
	}

	// Scans `view` byte by byte, growing `headBytesSeen` and resuming the
	// "\r\n\r\n" search across calls using `matchLength` (a standard KMP
	// substring search) so the terminator is still found when it straddles
	// two inbound reads. Checks the size cap on every byte — not just once
	// per buffer — so a single read that happens to carry an oversized head
	// AND its terminator (e.g. because the OS delivered the whole write in
	// one go) is still rejected instead of slipping through because the
	// terminator was technically "found".
	private func scanHead(_ view: ByteBufferView) -> ScanResult {
		for byte in view {
			headBytesSeen += 1
			if headBytesSeen > Self.maxRequestHeadBytes {
				return .exceeded
			}

			while matchLength > 0 && byte != Self.headTerminator[matchLength] {
				matchLength = Self.terminatorFailure[matchLength - 1]
			}
			if byte == Self.headTerminator[matchLength] {
				matchLength += 1
			}
			if matchLength == Self.headTerminator.count {
				return .terminatorFound
			}
		}
		return .stillCounting
	}

	private func rejectOversizedHead(context: ChannelHandlerContext) {
		let channel = context.channel
		let status = HTTPResponseStatus.requestHeaderFieldsTooLarge
		let responseText = "HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
		var buffer = channel.allocator.buffer(capacity: responseText.utf8.count)
		buffer.writeString(responseText)
		context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
			channel.close(promise: nil)
		}
	}
}

// Builds the standard HTTP/1.1 server codec stack — the same handlers
// `configureHTTPServerPipeline` installs (`HTTPResponseEncoder`,
// `ByteToMessageHandler<HTTPRequestDecoder>`, `HTTPServerPipelineHandler`,
// `NIOHTTPResponseHeadersValidator`, `HTTPServerProtocolErrorHandler`) — by
// hand, so the caller keeps a reference to each instance added. This lets
// ConnectHandler remove exactly these handlers later by reference instead of
// by the anonymous names `configureHTTPServerPipeline` would have used,
// which are not guaranteed stable across NIO versions. `RequestHeadSizeGuard`
// is added FIRST (before `HTTPResponseEncoder`/`HTTPRequestDecoder`) so it is
// the first handler to see raw inbound bytes off the socket.
enum HTTPServerCodec {
	static func install(on channel: Channel) throws -> [RemovableChannelHandler] {
		let headSizeGuard = RequestHeadSizeGuard()
		let responseEncoder = HTTPResponseEncoder()
		let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder())
		let pipeliningHandler = HTTPServerPipelineHandler()
		let headersValidator = NIOHTTPResponseHeadersValidator()
		let errorHandler = HTTPServerProtocolErrorHandler()

		let ops = channel.pipeline.syncOperations
		try ops.addHandler(headSizeGuard)
		try ops.addHandler(responseEncoder)
		try ops.addHandler(requestDecoder)
		try ops.addHandler(pipeliningHandler)
		try ops.addHandler(headersValidator)
		try ops.addHandler(errorHandler)

		return [headSizeGuard, responseEncoder, requestDecoder, pipeliningHandler, headersValidator, errorHandler]
	}
}
