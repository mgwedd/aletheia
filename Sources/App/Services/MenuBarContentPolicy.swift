enum MenuBarContentPolicy {
    static func canStartRecording(isLocked: Bool, isStarting: Bool) -> Bool {
        !isLocked && !isStarting
    }
}
