import Darwin
import Foundation
import ReviewCore

package struct ForcedRestartError: Error, LocalizedError {
    package var message: String

    package var errorDescription: String? {
        message
    }
}

package struct ForcedRestartSignalResult: Sendable {
    package var result: Int32
    package var errorNumber: Int32
}

package struct ForcedRestartRuntime: Sendable {
    package var isProcessAlive: @Sendable (pid_t) -> Bool
    package var processStartTime: @Sendable (pid_t) -> ProcessStartTime?
    package var isMatchingExecutable: @Sendable (pid_t, String?) -> Bool
    package var childProcessIDs: @Sendable (pid_t) -> [pid_t]
    package var currentProcessGroupID: @Sendable (pid_t) -> pid_t?
    package var signalProcess: @Sendable (pid_t, Int32) -> ForcedRestartSignalResult
    package var signalProcessGroup: @Sendable (pid_t, Int32) -> ForcedRestartSignalResult

    package static var live: Self {
        Self(
            isProcessAlive: { pid in ReviewCore.isProcessAlive(pid) },
            processStartTime: { pid in ReviewCore.processStartTime(of: pid) },
            isMatchingExecutable: { pid, expectedName in
                ReviewDiscovery.isMatchingExecutable(Int(pid), expectedName: expectedName)
            },
            childProcessIDs: { pid in ReviewCore.childProcessIDs(of: pid) },
            currentProcessGroupID: { pid in ReviewCore.currentProcessGroupID(of: pid) },
            signalProcess: { pid, signal in
                errno = 0
                let result = kill(pid, signal)
                return .init(result: result, errorNumber: errno)
            },
            signalProcessGroup: { pid, signal in
                errno = 0
                let result = killpg(pid, signal)
                return .init(result: result, errorNumber: errno)
            }
        )
    }
}

package func forceRestart(
    endpointRecord: LiveEndpointRecord,
    runtimeState: ReviewRuntimeStateRecord?,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2)
) async throws {
    try await forceRestart(
        endpointRecord: endpointRecord,
        runtimeState: runtimeState,
        terminateGracePeriod: terminateGracePeriod,
        killGracePeriod: killGracePeriod,
        clock: ContinuousClock(),
        runtime: .live
    )
}

package func forceRestart<C: Clock>(
    endpointRecord: LiveEndpointRecord,
    runtimeState: ReviewRuntimeStateRecord?,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2),
    clock: C,
    runtime: ForcedRestartRuntime = .live
) async throws where C.Duration == Duration {
    let appServerGroupIdentities = resolveAppServerGroupIdentities(
        endpointRecord: endpointRecord,
        runtimeState: runtimeState,
        runtime: runtime
    )

    let totalTimeout = terminateGracePeriod + killGracePeriod

    _ = signalServer(endpointRecord, signal: SIGTERM, runtime: runtime)
    signalProcessGroups(appServerGroupIdentities, signal: SIGTERM, runtime: runtime)

    let terminateDeadline = clock.now.advanced(by: terminateGracePeriod)
    while clock.now < terminateDeadline {
        if isServerAlive(endpointRecord, runtime: runtime) == false,
           hasLiveProcessGroups(appServerGroupIdentities, runtime: runtime) == false
        {
            return
        }

        _ = signalServer(endpointRecord, signal: SIGTERM, runtime: runtime)
        signalProcessGroups(appServerGroupIdentities, signal: SIGTERM, runtime: runtime)
        try await clock.sleep(
            until: clock.now.advanced(by: .milliseconds(100)),
            tolerance: nil
        )
    }

    let killDeadline = clock.now.advanced(by: killGracePeriod)
    while clock.now < killDeadline {
        if isServerAlive(endpointRecord, runtime: runtime) == false,
           hasLiveProcessGroups(appServerGroupIdentities, runtime: runtime) == false
        {
            return
        }

        _ = signalServer(endpointRecord, signal: SIGKILL, runtime: runtime)
        signalProcessGroups(appServerGroupIdentities, signal: SIGKILL, runtime: runtime)
        try await clock.sleep(
            until: clock.now.advanced(by: .milliseconds(100)),
            tolerance: nil
        )
    }

    if isServerAlive(endpointRecord, runtime: runtime)
        || hasLiveProcessGroups(appServerGroupIdentities, runtime: runtime)
    {
        throw ForcedRestartError(
            message: "existing server process \(endpointRecord.pid) did not stop within \(totalTimeout)"
        )
    }
}

private struct ProcessGroupIdentity: Hashable {
    var groupLeaderPID: pid_t
    var groupLeaderStartTime: ProcessStartTime?
    var anchorMembers: [ProcessIdentity]
}

private func resolveAppServerGroupIdentities(
    endpointRecord: LiveEndpointRecord,
    runtimeState: ReviewRuntimeStateRecord?,
    runtime: ForcedRestartRuntime
) -> [ProcessGroupIdentity] {
    var identitiesByGroupID: [pid_t: ProcessGroupIdentity] = [:]
    let runtimeStateMatchesServer = runtimeState.map {
        $0.serverPID == endpointRecord.pid && $0.serverStartTime == endpointRecord.serverStartTime
    } ?? true

    if let runtimeState,
       runtimeStateMatchesServer
    {
        let persistedIdentity = ProcessGroupIdentity(
            groupLeaderPID: pid_t(runtimeState.appServerProcessGroupLeaderPID),
            groupLeaderStartTime: runtimeState.appServerProcessGroupLeaderStartTime,
            anchorMembers: [
                ProcessIdentity(
                    pid: pid_t(runtimeState.appServerPID),
                    startTime: runtimeState.appServerStartTime
                )
            ]
        )
        identitiesByGroupID[persistedIdentity.groupLeaderPID] = persistedIdentity
    }

    if runtimeStateMatchesServer,
       isServerAlive(endpointRecord, runtime: runtime)
    {
        for identity in fallbackAppServerGroupIdentities(
            serverPID: pid_t(endpointRecord.pid),
            runtime: runtime
        ) {
            identitiesByGroupID[identity.groupLeaderPID] = mergeProcessGroupIdentity(
                existing: identitiesByGroupID[identity.groupLeaderPID],
                incoming: identity
            )
        }
    }

    return Array(identitiesByGroupID.values)
}

private func fallbackAppServerGroupIdentities(
    serverPID: pid_t,
    runtime: ForcedRestartRuntime
) -> [ProcessGroupIdentity] {
    var pending = runtime.childProcessIDs(serverPID)
    var visited: Set<pid_t> = []
    var groupIdentities: [pid_t: (groupLeaderStartTime: ProcessStartTime?, anchorMembers: Set<ProcessIdentity>)] = [:]

    while let pid = pending.popLast() {
        if visited.insert(pid).inserted == false {
            continue
        }
        guard runtime.isProcessAlive(pid) else {
            continue
        }
        guard let processStartTime = runtime.processStartTime(pid) else {
            continue
        }

        pending.append(contentsOf: runtime.childProcessIDs(pid))

        let groupLeaderPID = runtime.currentProcessGroupID(pid) ?? pid
        guard groupLeaderPID > 0 else {
            continue
        }
        let anchor = ProcessIdentity(pid: pid, startTime: processStartTime)
        var existing = groupIdentities[groupLeaderPID] ?? (nil, [])
        existing.anchorMembers.insert(anchor)
        if existing.groupLeaderStartTime == nil {
            existing.groupLeaderStartTime = runtime.processStartTime(groupLeaderPID)
        }
        groupIdentities[groupLeaderPID] = existing
    }

    return groupIdentities.map { groupLeaderPID, state in
        ProcessGroupIdentity(
            groupLeaderPID: groupLeaderPID,
            groupLeaderStartTime: state.groupLeaderStartTime,
            anchorMembers: state.anchorMembers.sorted {
                if $0.pid != $1.pid {
                    return $0.pid < $1.pid
                }
                if $0.startTime.seconds != $1.startTime.seconds {
                    return $0.startTime.seconds < $1.startTime.seconds
                }
                return $0.startTime.microseconds < $1.startTime.microseconds
            }
        )
    }
}

package func forceStopDiscoveredServerProcess(
    _ discovery: LiveEndpointRecord,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2),
    runtimeState: ReviewRuntimeStateRecord? = nil
) async throws {
    try await forceRestart(
        endpointRecord: discovery,
        runtimeState: runtimeState,
        terminateGracePeriod: terminateGracePeriod,
        killGracePeriod: killGracePeriod
    )
}

package func forceStopDiscoveredServerProcess<C: Clock>(
    _ discovery: LiveEndpointRecord,
    terminateGracePeriod: Duration = .seconds(10),
    killGracePeriod: Duration = .seconds(2),
    runtimeState: ReviewRuntimeStateRecord? = nil,
    clock: C,
    runtime: ForcedRestartRuntime = .live
) async throws where C.Duration == Duration {
    try await forceRestart(
        endpointRecord: discovery,
        runtimeState: runtimeState,
        terminateGracePeriod: terminateGracePeriod,
        killGracePeriod: killGracePeriod,
        clock: clock,
        runtime: runtime
    )
}

private func signalServer(
    _ discovery: LiveEndpointRecord,
    signal: Int32,
    runtime: ForcedRestartRuntime
) -> ForcedRestartSignalResult {
    let pid = pid_t(discovery.pid)
    guard runtime.isProcessAlive(pid),
          runtime.processStartTime(pid) == discovery.serverStartTime,
          runtime.isMatchingExecutable(pid, discovery.executableName)
    else {
        return .init(result: -1, errorNumber: ESRCH)
    }
    return runtime.signalProcess(pid, signal)
}

private func signalProcessGroups(
    _ identities: [ProcessGroupIdentity],
    signal: Int32,
    runtime: ForcedRestartRuntime
) {
    for identity in Set(identities) where isProcessGroupAlive(identity, runtime: runtime) {
        _ = runtime.signalProcessGroup(identity.groupLeaderPID, signal)
    }
}

private func isServerAlive(
    _ discovery: LiveEndpointRecord,
    runtime: ForcedRestartRuntime
) -> Bool {
    let pid = pid_t(discovery.pid)
    guard runtime.isProcessAlive(pid) else {
        return false
    }
    guard runtime.processStartTime(pid) == discovery.serverStartTime else {
        return false
    }
    return runtime.isMatchingExecutable(pid, discovery.executableName)
}

private func hasLiveProcessGroups(
    _ identities: [ProcessGroupIdentity],
    runtime: ForcedRestartRuntime
) -> Bool {
    Set(identities).contains { identity in
        isProcessGroupAlive(identity, runtime: runtime)
    }
}

private func isProcessGroupAlive(
    _ identity: ProcessGroupIdentity,
    runtime: ForcedRestartRuntime
) -> Bool {
    let probe = runtime.signalProcessGroup(identity.groupLeaderPID, 0)
    guard probe.result == 0 || probe.errorNumber == EPERM else {
        return false
    }

    if identity.anchorMembers.contains(where: { anchor in
        guard runtime.isProcessAlive(anchor.pid),
              runtime.processStartTime(anchor.pid) == anchor.startTime
        else {
            return false
        }
        return runtime.currentProcessGroupID(anchor.pid) == identity.groupLeaderPID
    }) {
        return true
    }

    if let currentStartTime = runtime.processStartTime(identity.groupLeaderPID) {
        guard let recordedStartTime = identity.groupLeaderStartTime else {
            return true
        }
        return currentStartTime == recordedStartTime
    }

    return identity.groupLeaderStartTime != nil
}

private func mergeProcessGroupIdentity(
    existing: ProcessGroupIdentity?,
    incoming: ProcessGroupIdentity
) -> ProcessGroupIdentity {
    guard let existing else {
        return incoming
    }

    let mergedGroupLeaderStartTime = existing.groupLeaderStartTime ?? incoming.groupLeaderStartTime
    let mergedAnchors = Array(
        Set(existing.anchorMembers).union(incoming.anchorMembers)
    ).sorted {
        if $0.pid != $1.pid {
            return $0.pid < $1.pid
        }
        if $0.startTime.seconds != $1.startTime.seconds {
            return $0.startTime.seconds < $1.startTime.seconds
        }
        return $0.startTime.microseconds < $1.startTime.microseconds
    }

    return ProcessGroupIdentity(
        groupLeaderPID: existing.groupLeaderPID,
        groupLeaderStartTime: mergedGroupLeaderStartTime,
        anchorMembers: mergedAnchors
    )
}
