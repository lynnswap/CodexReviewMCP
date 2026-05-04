import Darwin

package struct ProcessStartTime: Codable, Hashable, Sendable {
    package var seconds: UInt64
    package var microseconds: UInt64

    package init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

package struct ProcessIdentity: Hashable, Sendable {
    package var pid: pid_t
    package var startTime: ProcessStartTime

    package init(pid: pid_t, startTime: ProcessStartTime) {
        self.pid = pid
        self.startTime = startTime
    }
}

package func isProcessAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else {
        return false
    }
    if isZombieProcess(pid) {
        return false
    }
    let result = kill(pid, 0)
    return result == 0 || errno == EPERM
}

package func isZombieProcess(_ pid: pid_t) -> Bool {
    guard let info = processBSDInfo(of: pid) else {
        return false
    }
    return info.pbi_status == UInt8(SZOMB)
}

package func processStartTime(of pid: pid_t) -> ProcessStartTime? {
    guard let info = processBSDInfo(of: pid) else {
        return nil
    }
    return ProcessStartTime(
        seconds: info.pbi_start_tvsec,
        microseconds: info.pbi_start_tvusec
    )
}

package func currentProcessGroupID(of pid: pid_t) -> pid_t? {
    let groupID = getpgid(pid)
    guard groupID > 0 else {
        return nil
    }
    return groupID
}

package func childProcessIDs(of pid: pid_t) -> [pid_t] {
    let rawCount = proc_listchildpids(pid, nil, 0)
    guard rawCount > 0 else {
        return []
    }

    let stride = MemoryLayout<pid_t>.stride
    let bufferCapacity = max(Int(rawCount), Int(rawCount) / stride, 1)
    var buffer = [pid_t](repeating: 0, count: bufferCapacity)
    let filled = proc_listchildpids(pid, &buffer, Int32(buffer.count * stride))
    guard filled > 0 else {
        return []
    }

    let childCount: Int
    if Int(filled) > buffer.count {
        childCount = Int(filled) / stride
    } else {
        childCount = Int(filled)
    }
    return Array(buffer.prefix(childCount)).filter { $0 > 0 }
}

package func isMatchingProcessIdentity(_ identity: ProcessIdentity) -> Bool {
    guard isProcessAlive(identity.pid) else {
        return false
    }
    return processStartTime(of: identity.pid) == identity.startTime
}

private func processBSDInfo(of pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
    guard result == expectedSize else {
        return nil
    }
    return info
}
