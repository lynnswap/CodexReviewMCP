import Testing
@testable import ReviewHTTPServer

@Suite
struct ReviewHTTPServerTests {
    @Test func reviewServerConfigurationNormalizesEndpointPath() {
        let configuration = ReviewServerConfiguration(endpoint: "mcp")
        #expect(configuration.endpoint == "/mcp")
    }

    @Test func normalizedDiscoveryHostMapsWildcardBindsToLocalhost() {
        #expect(normalizedDiscoveryHost(configuredHost: "0.0.0.0", boundHost: "0.0.0.0") == "localhost")
        #expect(normalizedDiscoveryHost(configuredHost: "::", boundHost: "::") == "localhost")
        #expect(normalizedDiscoveryHost(configuredHost: "localhost", boundHost: "127.0.0.1") == "localhost")
    }

    @Test func deleteSuccessStatusIncludesNoContent() {
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 200))
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 204))
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 404))
        #expect(shouldCloseSessionAfterDelete(method: "DELETE", statusCode: 500) == false)
        #expect(shouldCloseSessionAfterDelete(method: "POST", statusCode: 204) == false)
    }
}
