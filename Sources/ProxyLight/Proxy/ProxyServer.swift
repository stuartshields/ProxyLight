import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

final class ProxyServer {
	private let port: Int
	private let engineProvider: @Sendable () -> MappingEngine
	private let ca: CertificateAuthority?
	private let group: MultiThreadedEventLoopGroup
	private var channel: Channel?

	init(port: Int, engineProvider: @escaping @Sendable () -> MappingEngine, ca: CertificateAuthority?) {
		self.port = port
		self.engineProvider = engineProvider
		self.ca = ca
		self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
	}

	func start() throws -> Int {
		let provider = engineProvider
		let ca = self.ca
		let bootstrap = ServerBootstrap(group: group)
			.serverChannelOption(ChannelOptions.backlog, value: 64)
			.serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
			.childChannelInitializer { channel in
				// Built by hand (not `configureHTTPServerPipeline`) so ConnectHandler
				// can hold references to these exact handler instances and remove
				// them later when a CONNECT reconfigures the channel. See the note
				// on `HTTPServerCodec` in ConnectHandler.swift.
				channel.eventLoop.makeCompletedFuture(withResultOf: {
					let codecHandlers = try HTTPServerCodec.install(on: channel)
					try channel.pipeline.syncOperations.addHandler(
						ConnectHandler(engineProvider: provider, ca: ca, httpServerCodecHandlers: codecHandlers)
					)
				})
			}
		let bound = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
		self.channel = bound
		return bound.localAddress!.port!
	}

	func stop() throws {
		try channel?.close().wait()
		channel = nil
		try group.syncShutdownGracefully()
	}
}
