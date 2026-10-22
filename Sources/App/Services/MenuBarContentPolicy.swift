enum MenuBarContentPolicy {
    static func showsPatientNames(isLocked: Bool) -> Bool { !isLocked }
    static func showsLevels(isLocked: Bool) -> Bool { !isLocked }
    static func canStartRecording(isLocked: Bool, isStarting: Bool) -> Bool {
        !isLocked && !isStarting
    }
    static func keepsRecording(isLocked: Bool, isRecording: Bool) -> Bool { isRecording }
}
