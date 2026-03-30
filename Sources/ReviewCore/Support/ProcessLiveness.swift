import Darwin

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
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
    guard result == expectedSize else {
        return false
    }
    return info.pbi_status == UInt8(SZOMB)
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
