import Darwin
import Foundation
import ReviewDomain
import ReviewPlatform

struct AppServerLaunchCommand {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
}

struct SpawnedAppServerProcess {
    var pid: pid_t
    var stdinPipe: Pipe
    var stdoutPipe: Pipe
    var stderrPipe: Pipe
}

func makeAppServerLaunchCommand(
    codexCommand: String,
    environment: [String: String],
    codexHomeURL: URL
) throws -> AppServerLaunchCommand {
    guard let resolvedExecutable = resolveCodexCommand(
        requestedCommand: codexCommand,
        environment: environment,
        currentDirectory: FileManager.default.currentDirectoryPath
    ) else {
        throw ReviewError.spawnFailed(
            "Unable to locate \(codexCommand) executable. Set --codex-command or ensure PATH contains \(codexCommand)."
        )
    }

    var effectiveEnvironment = environment
    effectiveEnvironment["CODEX_HOME"] = codexHomeURL.path

    return AppServerLaunchCommand(
        executable: resolvedExecutable,
        arguments: reviewMCPCodexCommandArguments([
            "app-server",
            "--listen", "stdio://"
        ]),
        environment: effectiveEnvironment
    )
}

func spawnAppServerProcess(
    _ command: AppServerLaunchCommand
) throws -> SpawnedAppServerProcess {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    var fileActions: posix_spawn_file_actions_t? = nil
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
        throw ReviewError.spawnFailed("failed to initialize app-server spawn file actions.")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let stdinReadFD = stdinPipe.fileHandleForReading.fileDescriptor
    let stdinWriteFD = stdinPipe.fileHandleForWriting.fileDescriptor
    let stdoutReadFD = stdoutPipe.fileHandleForReading.fileDescriptor
    let stdoutWriteFD = stdoutPipe.fileHandleForWriting.fileDescriptor
    let stderrReadFD = stderrPipe.fileHandleForReading.fileDescriptor
    let stderrWriteFD = stderrPipe.fileHandleForWriting.fileDescriptor

    for fileDescriptor in [stdinWriteFD, stdoutReadFD, stderrReadFD] {
        guard posix_spawn_file_actions_addclose(&fileActions, fileDescriptor) == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio cleanup.")
        }
    }

    for (source, destination) in [
        (stdinReadFD, STDIN_FILENO),
        (stdoutWriteFD, STDOUT_FILENO),
        (stderrWriteFD, STDERR_FILENO),
    ] where source != destination {
        guard posix_spawn_file_actions_adddup2(&fileActions, source, destination) == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio redirection.")
        }
        guard posix_spawn_file_actions_addclose(&fileActions, source) == 0 else {
            throw ReviewError.spawnFailed("failed to configure app-server stdio source cleanup.")
        }
    }

    var spawnAttributes: posix_spawnattr_t? = nil
    guard posix_spawnattr_init(&spawnAttributes) == 0 else {
        throw ReviewError.spawnFailed("failed to initialize app-server spawn attributes.")
    }
    defer { posix_spawnattr_destroy(&spawnAttributes) }

    let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&spawnAttributes, spawnFlags) == 0,
          posix_spawnattr_setpgroup(&spawnAttributes, 0) == 0
    else {
        throw ReviewError.spawnFailed("failed to configure app-server process group.")
    }

    let argv = try allocateCStringArray([command.executable] + command.arguments)
    let envp = try allocateCStringArray(command.environment.map { "\($0.key)=\($0.value)" })
    defer {
        for pointer in argv where pointer != nil {
            free(pointer)
        }
        for pointer in envp where pointer != nil {
            free(pointer)
        }
    }

    var pid: pid_t = 0
    let spawnStatus = posix_spawn(
        &pid,
        command.executable,
        &fileActions,
        &spawnAttributes,
        argv,
        envp
    )
    guard spawnStatus == 0 else {
        let message = String(cString: strerror(spawnStatus))
        throw ReviewError.spawnFailed("failed to start app-server: \(message)")
    }

    try? stdinPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()

    return SpawnedAppServerProcess(
        pid: pid,
        stdinPipe: stdinPipe,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe
    )
}

func terminateManagedRuntime(
    processIdentity: ProcessIdentity,
    processGroupIdentity: ProcessIdentity,
    signalDedicatedProcessGroup: Bool,
    connection: AppServerSharedTransportConnection,
    waitTask: Task<Void, Never>,
    stdoutTask: Task<Void, Never>,
    stderrTask: Task<Void, Never>,
    clock: any ReviewClock
) async {
    await connection.shutdown()
    let excludedGroupLeaderPIDs = trackedGroupExclusionSet(
        processIdentity: processIdentity,
        processGroupIdentity: processGroupIdentity,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup
    )
    let individuallyTrackedGroupLeaderPID = individuallyTrackedProcessGroupLeaderPID(
        processIdentity: processIdentity,
        processGroupIdentity: processGroupIdentity,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup
    )
    var trackedChildGroupIdentities = descendantProcessGroupIdentities(
        rootIdentity: processIdentity,
        excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
    )
    var trackedExcludedGroupProcessIdentities = individuallyTrackedGroupLeaderPID.map {
        descendantProcessIdentities(rootIdentity: processIdentity, inProcessGroup: $0)
    } ?? []
    signalManagedRuntime(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupIdentity.pid,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup,
        signal: SIGTERM
    )
    signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
    signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)

    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        trackedChildGroupIdentities = mergeProcessIdentities(
            trackedChildGroupIdentities,
            descendantProcessGroupIdentities(
                rootIdentity: processIdentity,
                excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
            )
        )
        if let individuallyTrackedGroupLeaderPID {
            trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
                trackedExcludedGroupProcessIdentities,
                descendantProcessIdentities(
                    rootIdentity: processIdentity,
                    inProcessGroup: individuallyTrackedGroupLeaderPID
                )
            )
        }
        if managedRuntimeStopped(
            processIdentity: processIdentity,
            processGroupLeaderPID: processGroupIdentity.pid,
            signalDedicatedProcessGroup: signalDedicatedProcessGroup
        ) && hasLiveTrackedProcessGroups(trackedChildGroupIdentities) == false
            && hasLiveTrackedProcesses(trackedExcludedGroupProcessIdentities) == false
        {
            break
        }
        signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
        signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)
        try? await clock.sleep(for: .milliseconds(100))
    }

    trackedChildGroupIdentities = mergeProcessIdentities(
        trackedChildGroupIdentities,
        descendantProcessGroupIdentities(
            rootIdentity: processIdentity,
            excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
        )
    )
    if let individuallyTrackedGroupLeaderPID {
        trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
            trackedExcludedGroupProcessIdentities,
            descendantProcessIdentities(
                rootIdentity: processIdentity,
                inProcessGroup: individuallyTrackedGroupLeaderPID
            )
        )
    }
    if managedRuntimeStopped(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupIdentity.pid,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup
    ) == false
        || hasLiveTrackedProcessGroups(trackedChildGroupIdentities)
        || hasLiveTrackedProcesses(trackedExcludedGroupProcessIdentities)
    {
        signalManagedRuntime(
            processIdentity: processIdentity,
            processGroupLeaderPID: processGroupIdentity.pid,
            signalDedicatedProcessGroup: signalDedicatedProcessGroup,
            signal: SIGKILL
        )
        signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGKILL)
        signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGKILL)
    }

    _ = await waitTask.result
    _ = await stdoutTask.value
    _ = await stderrTask.value
}

func terminateFailedSpawnedProcess(
    processIdentity: ProcessIdentity,
    processGroupLeaderPID: pid_t,
    signalDedicatedProcessGroup: Bool,
    clock: any ReviewClock
) async {
    let excludedGroupLeaderPIDs: Set<pid_t> =
        signalDedicatedProcessGroup && processGroupLeaderPID > 0 ? [processGroupLeaderPID] : []
    let individuallyTrackedGroupLeaderPID = currentProcessGroupID(of: processIdentity.pid)
    var trackedChildGroupIdentities = descendantProcessGroupIdentities(
        rootIdentity: processIdentity,
        excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
    )
    var trackedExcludedGroupProcessIdentities = individuallyTrackedGroupLeaderPID.map {
        descendantProcessIdentities(rootIdentity: processIdentity, inProcessGroup: $0)
    } ?? []
    signalManagedRuntime(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupLeaderPID,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup,
        signal: SIGTERM
    )
    signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
    signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)

    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        trackedChildGroupIdentities = mergeProcessIdentities(
            trackedChildGroupIdentities,
            descendantProcessGroupIdentities(
                rootIdentity: processIdentity,
                excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
            )
        )
        if let individuallyTrackedGroupLeaderPID {
            trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
                trackedExcludedGroupProcessIdentities,
                descendantProcessIdentities(
                    rootIdentity: processIdentity,
                    inProcessGroup: individuallyTrackedGroupLeaderPID
                )
            )
        }
        let result = waitpid(processIdentity.pid, nil, WNOHANG)
        if (result == processIdentity.pid || (result == -1 && errno == ECHILD)),
           hasLiveTrackedProcessGroups(trackedChildGroupIdentities) == false,
           hasLiveTrackedProcesses(trackedExcludedGroupProcessIdentities) == false
        {
            return
        }
        signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGTERM)
        signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGTERM)
        try? await clock.sleep(for: .milliseconds(100))
    }

    trackedChildGroupIdentities = mergeProcessIdentities(
        trackedChildGroupIdentities,
        descendantProcessGroupIdentities(
            rootIdentity: processIdentity,
            excludingGroupLeaderPIDs: excludedGroupLeaderPIDs
        )
    )
    if let individuallyTrackedGroupLeaderPID {
        trackedExcludedGroupProcessIdentities = mergeProcessIdentities(
            trackedExcludedGroupProcessIdentities,
            descendantProcessIdentities(
                rootIdentity: processIdentity,
                inProcessGroup: individuallyTrackedGroupLeaderPID
            )
        )
    }
    signalManagedRuntime(
        processIdentity: processIdentity,
        processGroupLeaderPID: processGroupLeaderPID,
        signalDedicatedProcessGroup: signalDedicatedProcessGroup,
        signal: SIGKILL
    )
    signalTrackedProcessGroups(trackedChildGroupIdentities, signal: SIGKILL)
    signalTrackedProcesses(trackedExcludedGroupProcessIdentities, signal: SIGKILL)
    reapSpawnedProcess(pid: processIdentity.pid)
}

func signalManagedRuntime(
    processIdentity: ProcessIdentity,
    processGroupLeaderPID: pid_t,
    signalDedicatedProcessGroup: Bool,
    signal: Int32
) {
    if isMatchingProcessIdentity(processIdentity) {
        _ = kill(processIdentity.pid, signal)
    }
    if signalDedicatedProcessGroup, processGroupLeaderPID > 0 {
        _ = killpg(processGroupLeaderPID, signal)
    }
}

func managedRuntimeStopped(
    processIdentity: ProcessIdentity,
    processGroupLeaderPID: pid_t,
    signalDedicatedProcessGroup: Bool
) -> Bool {
    let processStopped = isMatchingProcessIdentity(processIdentity) == false
    guard signalDedicatedProcessGroup else {
        return processStopped
    }
    return processStopped && isProcessGroupGone(processGroupLeaderPID)
}

func trackedGroupExclusionSet(
    processIdentity: ProcessIdentity,
    processGroupIdentity: ProcessIdentity,
    signalDedicatedProcessGroup: Bool
) -> Set<pid_t> {
    var excluded: Set<pid_t> = []
    if signalDedicatedProcessGroup {
        excluded.insert(processGroupIdentity.pid)
    }
    if let currentProcessGroupID = currentProcessGroupID(of: processIdentity.pid) {
        excluded.insert(currentProcessGroupID)
    }
    return excluded.filter { $0 > 0 }
}

func individuallyTrackedProcessGroupLeaderPID(
    processIdentity: ProcessIdentity,
    processGroupIdentity: ProcessIdentity,
    signalDedicatedProcessGroup: Bool
) -> pid_t? {
    guard let currentProcessGroupID = currentProcessGroupID(of: processIdentity.pid),
          currentProcessGroupID > 0
    else {
        return nil
    }
    if signalDedicatedProcessGroup, currentProcessGroupID == processGroupIdentity.pid {
        return nil
    }
    return currentProcessGroupID
}

func descendantProcessGroupIdentities(
    rootIdentity: ProcessIdentity,
    excludingGroupLeaderPIDs: Set<pid_t>
) -> [ProcessIdentity] {
    guard canTraverseDescendants(of: rootIdentity) else {
        return []
    }

    var pending = snapshotChildProcessIdentities(of: rootIdentity)
    var visited: Set<ProcessIdentity> = []
    var identities: Set<ProcessIdentity> = []

    while let identity = pending.popLast() {
        if visited.insert(identity).inserted == false {
            continue
        }
        pending.append(contentsOf: snapshotChildProcessIdentities(of: identity))

        let groupLeaderPID = currentProcessGroupID(of: identity.pid) ?? identity.pid
        guard groupLeaderPID > 0,
              excludingGroupLeaderPIDs.contains(groupLeaderPID) == false,
              let groupLeaderStartTime = processStartTime(of: groupLeaderPID)
        else {
            continue
        }

        identities.insert(
            ProcessIdentity(
                pid: groupLeaderPID,
                startTime: groupLeaderStartTime
            )
        )
    }

    return Array(identities)
}

func descendantProcessIdentities(rootIdentity: ProcessIdentity) -> [ProcessIdentity] {
    guard canTraverseDescendants(of: rootIdentity) else {
        return []
    }

    var pending = snapshotChildProcessIdentities(of: rootIdentity)
    var visited: Set<ProcessIdentity> = []
    var identities: [ProcessIdentity] = []

    while let identity = pending.popLast() {
        if visited.insert(identity).inserted == false {
            continue
        }
        identities.append(identity)
        pending.append(contentsOf: snapshotChildProcessIdentities(of: identity))
    }

    return identities
}

func descendantProcessIdentities(
    rootIdentity: ProcessIdentity,
    inProcessGroup processGroupLeaderPID: pid_t
) -> [ProcessIdentity] {
    guard processGroupLeaderPID > 0 else {
        return []
    }

    return descendantProcessIdentities(rootIdentity: rootIdentity).filter { identity in
        currentProcessGroupID(of: identity.pid) == processGroupLeaderPID
    }
}

func canTraverseDescendants(of identity: ProcessIdentity) -> Bool {
    processStartTime(of: identity.pid) == identity.startTime
}

func snapshotChildProcessIdentities(of parentIdentity: ProcessIdentity) -> [ProcessIdentity] {
    guard canTraverseDescendants(of: parentIdentity) else {
        return []
    }

    return childProcessIDs(of: parentIdentity.pid).compactMap { childPID in
        guard let startTime = processStartTime(of: childPID) else {
            return nil
        }
        return ProcessIdentity(pid: childPID, startTime: startTime)
    }
}

func mergeProcessIdentities(
    _ lhs: [ProcessIdentity],
    _ rhs: [ProcessIdentity]
) -> [ProcessIdentity] {
    Array(Set(lhs).union(rhs))
}

func signalTrackedProcessGroups(
    _ identities: [ProcessIdentity],
    signal: Int32
) {
    for identity in Set(identities) where isTrackedProcessGroupAlive(identity) {
        _ = killpg(identity.pid, signal)
    }
}

func hasLiveTrackedProcessGroups(_ identities: [ProcessIdentity]) -> Bool {
    Set(identities).contains { identity in
        isTrackedProcessGroupAlive(identity)
    }
}

func signalTrackedProcesses(
    _ identities: [ProcessIdentity],
    signal: Int32
) {
    for identity in Set(identities) where isMatchingProcessIdentity(identity) {
        _ = kill(identity.pid, signal)
    }
}

func hasLiveTrackedProcesses(_ identities: [ProcessIdentity]) -> Bool {
    Set(identities).contains { identity in
        isMatchingProcessIdentity(identity)
    }
}

func isTrackedProcessGroupAlive(_ identity: ProcessIdentity) -> Bool {
    let probe = killpg(identity.pid, 0)
    guard probe == 0 || errno == EPERM else {
        return false
    }
    if let currentStartTime = processStartTime(of: identity.pid) {
        return currentStartTime == identity.startTime
    }
    return true
}

func isProcessGroupGone(_ groupLeaderPID: pid_t) -> Bool {
    guard groupLeaderPID > 0 else {
        return true
    }
    errno = 0
    let result = killpg(groupLeaderPID, 0)
    return result == -1 && errno == ESRCH
}

func reapSpawnedProcess(pid: pid_t) {
    var status: Int32 = 0
    while true {
        let result = waitpid(pid, &status, 0)
        if result == pid || (result == -1 && errno == ECHILD) {
            return
        }
        if result == -1 && errno == EINTR {
            continue
        }
        return
    }
}

func terminateSpawnedProcessWithoutIdentity(
    pid: pid_t,
    clock: any ReviewClock
) async {
    var status: Int32 = 0
    _ = kill(pid, SIGTERM)
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) {
            return
        }
        try? await clock.sleep(for: .milliseconds(100))
    }
    _ = kill(pid, SIGKILL)
    reapSpawnedProcess(pid: pid)
}

func allocateCStringArray(
    _ strings: [String]
) throws -> [UnsafeMutablePointer<CChar>?] {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    pointers.reserveCapacity(strings.count + 1)
    do {
        for string in strings {
            guard let pointer = strdup(string) else {
                throw ReviewError.spawnFailed("failed to allocate app-server spawn arguments.")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    } catch {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
        throw error
    }
}
