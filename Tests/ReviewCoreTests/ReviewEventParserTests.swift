import Foundation
import Testing
@testable import ReviewCore

@Suite
struct AppServerProtocolTests {
    @Test func appServerJSONLFramerSplitsCompleteMessages() {
        var framer = AppServerJSONLFramer()

        let firstMessages = framer.append(Data("{\"id\":1}\n{\"id\":".utf8))
        let secondMessages = framer.append(Data("2}\n".utf8))

        #expect(firstMessages.count == 1)
        #expect(String(decoding: firstMessages[0], as: UTF8.self) == "{\"id\":1}")
        #expect(secondMessages.count == 1)
        #expect(String(decoding: secondMessages[0], as: UTF8.self) == "{\"id\":2}")
    }

    @Test func appServerJSONLFramerFlushesRemainingMessageOnFinish() {
        var framer = AppServerJSONLFramer()
        _ = framer.append(Data("{\"method\":\"initialized\"}".utf8))

        let flushed = framer.finish()
        #expect(flushed.count == 1)
        #expect(String(decoding: flushed[0], as: UTF8.self) == "{\"method\":\"initialized\"}")
    }

    @Test func appServerRequestIDParsesSupportedJSONShapes() {
        #expect(AppServerRequestID(jsonObject: "1") == .string("1"))
        #expect(AppServerRequestID(jsonObject: 7) == .integer(7))
        #expect(AppServerRequestID(jsonObject: NSNumber(value: 11)) == .integer(11))
        #expect(AppServerRequestID(jsonObject: NSNumber(value: 3.5)) == .double(3.5))
    }
}
