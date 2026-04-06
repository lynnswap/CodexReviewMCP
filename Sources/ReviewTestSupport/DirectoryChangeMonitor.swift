import Dispatch
import Foundation

public final class DirectoryChangeMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let source: DispatchSourceFileSystemObject
    private let fileDescriptor: CInt
    private let signalSource = AsyncSignal()

    public init(directoryURL: URL) throws {
        queue = DispatchQueue(label: "ReviewTestSupport.DirectoryChangeMonitor")
        fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [signalSource] in
            Task {
                await signalSource.signal()
            }
        }
        source.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    public func eventCount() async -> Int {
        await signalSource.count()
    }

    public func waitForChange(after eventCount: Int) async {
        await signalSource.wait(untilCount: eventCount + 1)
    }

    public func cancel() {
        source.cancel()
    }
}
