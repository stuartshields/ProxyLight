import NIOCore
import NIOHTTP1
import Foundation

// Sits between the HTTP server codec and ConnectHandler on the OUTER listener
// pipeline only. Answers requests addressed to the listener itself — the PAC
// file macOS and browsers fetch directly — and passes proxied requests
// through untouched. Origin-form URIs are self-addressed by definition
// (proxied requests always arrive absolute-form, so origin-form means the
// client connected straight to us); absolute-form URIs are self-addressed
// when they name a loopback host with our bound port. Answering non-PAC
// self-addressed requests with 404 also closes the latent self-proxy loop
// (a proxied request targeting 127.0.0.1:<listenPort> used to make the proxy
// connect to itself).
//
// NOT installed in the rebuilt post-CONNECT MITM pipeline: MITM'd inner
// requests are origin-form but must be proxied, not answered locally.
final class PACResponder: ChannelInboundHandler, RemovableChannelHandler {
	typealias InboundIn = HTTPServerRequestPart
	typealias OutboundOut = HTTPServerResponsePart

	static let pacPath = "/proxy.pac"

	private let engineProvider: @Sendable () -> MappingEngine
	// The head of the self-addressed request currently being swallowed;
	// nil while passing proxied traffic through.
	private var selfAddressedHead: HTTPRequestHead?

	init(engineProvider: @escaping @Sendable () -> MappingEngine) {
		self.engineProvider = engineProvider
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch unwrapInboundIn(data) {
		case .head(let head):
			if head.method != .CONNECT,
				Self.isSelfAddressed(uri: head.uri, boundPort: context.channel.localAddress?.port) {
				selfAddressedHead = head
			} else {
				selfAddressedHead = nil
				context.fireChannelRead(data)
			}
		case .body:
			if selfAddressedHead == nil {
				context.fireChannelRead(data)
			}
		case .end:
			if let head = selfAddressedHead {
				selfAddressedHead = nil
				respond(context: context, head: head)
			} else {
				context.fireChannelRead(data)
			}
		}
	}

	static func isSelfAddressed(uri: String, boundPort: Int?) -> Bool {
		if uri.hasPrefix("/") { return true }
		guard let comps = URLComponents(string: uri), let host = comps.host else { return false }
		let loopback: Set<String> = ["127.0.0.1", "localhost", "::1"]
		guard loopback.contains(host.lowercased()) else { return false }
		let port = comps.port ?? (comps.scheme == "https" ? 443 : 80)
		return port == boundPort
	}

	private func respond(context: ChannelHandlerContext, head: HTTPRequestHead) {
		let path = requestPath(of: head.uri)
		guard path == Self.pacPath, head.method == .GET || head.method == .HEAD,
			let port = context.channel.localAddress?.port else {
			ProxyGlueHandler.sendError(context.channel, status: .notFound, message: "Not found")
			return
		}
		let pac = PACGenerator.generate(hostnames: engineProvider().pacHostnames, proxyPort: port)
		var headers = HTTPHeaders()
		headers.add(name: "Content-Type", value: "application/x-ns-proxy-autoconfig")
		headers.add(name: "Cache-Control", value: "no-cache")
		headers.add(name: "Content-Length", value: String(pac.utf8.count))
		context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
		if head.method == .GET {
			var buf = context.channel.allocator.buffer(capacity: pac.utf8.count)
			buf.writeString(pac)
			context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
		}
		// Honor the client's keep-alive intent: PAC fetchers commonly send
		// Connection: close and then wait for the socket to close.
		let channel = context.channel
		let done = context.writeAndFlush(wrapOutboundOut(.end(nil)))
		if !head.isKeepAlive {
			done.whenComplete { _ in channel.close(promise: nil) }
		}
	}

	// Path component of either an origin-form ("/proxy.pac?v=1") or
	// absolute-form ("http://127.0.0.1:9876/proxy.pac?v=1") request URI.
	private func requestPath(of uri: String) -> String {
		if uri.hasPrefix("/") {
			return uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
		}
		return URLComponents(string: uri)?.path ?? uri
	}
}
