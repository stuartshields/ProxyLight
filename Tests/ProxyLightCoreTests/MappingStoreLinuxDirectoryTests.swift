import Testing
import Foundation
@testable import ProxyLightCore

#if !os(macOS)
@Test func defaultDirectoryUsesXDGConfigHomeWhenSet() {
	let dir = MappingStore.defaultDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/xdg-test"])
	#expect(dir.path == "/tmp/xdg-test/proxylight")
}

@Test func defaultDirectoryFallsBackToDotConfigWhenXDGUnset() {
	let dir = MappingStore.defaultDirectory(environment: ["HOME": "/home/tester"])
	#expect(dir.path == "/home/tester/.config/proxylight")
}
#endif
