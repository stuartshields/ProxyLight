import Testing
import NIOCore
import NIOEmbedded
@testable import ProxyLight

// Exercises `RequestHeadSizeGuard`'s cross-`channelRead` state directly via
// `EmbeddedChannel`, which feeds one `ByteBuffer` per `writeInbound` call
// deterministically -- unlike a real socket, nothing coalesces or splits the
// writes for us, so these tests can pin down exactly where a byte lands
// relative to the terminator scan and the size cap.

// `EmbeddedChannel` starts out registered but not yet "active" (matching a
// real socket channel before `connect`/`accept` completes) -- `isActive`
// reads false until it is explicitly connected once.
private func connectedGuardChannel() throws -> EmbeddedChannel {
	let channel = EmbeddedChannel(handler: RequestHeadSizeGuard())
	try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
	return channel
}

// The "\r\n\r\n" end-of-headers terminator is split across two separate
// reads (buffer 1 ends "...\r\n\r", buffer 2 is just "\n"). The KMP-style
// scan in `scanHead` carries `matchLength` across calls specifically to
// catch this case; if that state didn't survive the call boundary, the
// terminator would never be recognized and the connection would either
// hang in `.counting` forever or (if enough more bytes arrived) be
// incorrectly rejected as oversized.
@Test func terminatorSplitAcrossBuffersIsDetected() throws {
	let channel = try connectedGuardChannel()
	defer { _ = try? channel.finish() }

	var firstPart = channel.allocator.buffer(capacity: 32)
	firstPart.writeString("GET / HTTP/1.1\r\nHost: x\r\n\r")
	var secondPart = channel.allocator.buffer(capacity: 1)
	secondPart.writeString("\n")

	try channel.writeInbound(firstPart)
	try channel.writeInbound(secondPart)

	guard let forwarded1 = try channel.readInbound(as: ByteBuffer.self) else {
		Issue.record("first buffer was not forwarded downstream")
		return
	}
	guard let forwarded2 = try channel.readInbound(as: ByteBuffer.self) else {
		Issue.record("second buffer (the lone terminator byte) was not forwarded downstream")
		return
	}
	#expect(forwarded1 == firstPart)
	#expect(forwarded2 == secondPart)

	// A recognized terminator on a normal-sized head must never produce a
	// rejection response, and the channel must stay open.
	let outbound = try channel.readOutbound(as: ByteBuffer.self)
	#expect(outbound == nil)
	#expect(channel.isActive)
}

// Feeds an over-cap header block as many small buffers rather than one big
// one, proving the byte counter (`headBytesSeen`) accumulates correctly
// across calls instead of resetting per `channelRead` invocation -- which
// would make it possible to sneak an oversized head through as long as no
// single read exceeded the cap on its own.
@Test func oversizedHeadAcrossManySmallBuffersReturns431() throws {
	let channel = try connectedGuardChannel()
	defer { _ = try? channel.finish() }

	let chunkSize = 2048
	let cap = RequestHeadSizeGuard.maxRequestHeadBytes
	// No "\r\n\r\n" anywhere in this stream, so the guard can only ever
	// stop counting via the size cap, never via a terminator match.
	let chunkText = String(repeating: "A", count: chunkSize)
	let chunksUnderCap = cap / chunkSize // exactly at the cap, not yet over it
	let totalChunks = chunksUnderCap + 1 // the one that tips it over

	var forwardedCount = 0
	for _ in 1...totalChunks {
		var chunk = channel.allocator.buffer(capacity: chunkSize)
		chunk.writeString(chunkText)
		try channel.writeInbound(chunk)
		while try channel.readInbound(as: ByteBuffer.self) != nil {
			forwardedCount += 1
		}
	}

	// Every chunk up to (and including) the cap was forwarded; the chunk
	// that pushed the running total over the cap was not.
	#expect(forwardedCount == chunksUnderCap)

	guard let outbound = try channel.readOutbound(as: ByteBuffer.self) else {
		Issue.record("guard did not write a rejection response outbound")
		return
	}
	let responseText = outbound.getString(at: outbound.readerIndex, length: outbound.readableBytes)
	#expect(responseText?.contains("431") == true)
	#expect(!channel.isActive)
}

// A small, well-under-cap header block followed by a body far larger than
// the 64 KB cap must NOT be rejected: once the terminator is found the
// guard becomes a permanent pass-through and stops counting entirely, so
// body size (unlike head size) is never subject to this cap.
@Test func largeBodyUnderSmallHeadIsNotRejected() throws {
	let channel = try connectedGuardChannel()
	defer { _ = try? channel.finish() }

	let bodySize = 128 * 1024
	#expect(bodySize > RequestHeadSizeGuard.maxRequestHeadBytes)

	var head = channel.allocator.buffer(capacity: 64)
	head.writeString("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \(bodySize)\r\n\r\n")
	var body = channel.allocator.buffer(capacity: bodySize)
	body.writeString(String(repeating: "B", count: bodySize))

	try channel.writeInbound(head)
	try channel.writeInbound(body)

	guard let forwardedHead = try channel.readInbound(as: ByteBuffer.self) else {
		Issue.record("head was not forwarded downstream")
		return
	}
	guard let forwardedBody = try channel.readInbound(as: ByteBuffer.self) else {
		Issue.record("oversized body was not forwarded downstream")
		return
	}
	#expect(forwardedHead == head)
	#expect(forwardedBody == body)

	let outbound = try channel.readOutbound(as: ByteBuffer.self)
	#expect(outbound == nil)
	#expect(channel.isActive)
}
