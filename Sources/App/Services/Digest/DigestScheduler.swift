import AppKit
import Combine
import Foundation

/// Prepares session summaries (digests) in the background, only for sessions
/// that need one (`DigestSchedulePolicy.needsSummary`), only while nothing else
/// is going on (`DigestSchedulePolicy.pauseReason`), newest first. Each build
/// goes through `DigestBuilder.ensureDigest`, whose section summaries are kept
/// as they are written, so a pause or a quit loses at most the section in
/// progress. Nothing here sends anything off the Mac: every call is to the
/// local model through the shared `InferenceQueue`, at its lowest priority.
@MainActor
final class DigestScheduler: ObservableObject {
    /// One patient's sessions that need a summary, and how many have one.
    struct Count: Equatable {
        var ready: Int
        var needed: Int
    }

    /// What the scheduler reads from the rest of the app, each time it looks.
    struct Context {
        let store: Store
        let patients: [Patient]
        let service: AssistantService
    }

    @Published private(set) var counts: [UUID: Count] = [:]
    @Published private(set) var pauseReason: DigestPauseReason?
    /// The patient whose session is being summarized right now.
    @Published private(set) var buildingPatientID: UUID?
    /// "Prepare now" was asked for and the work it started isn't done.
    @Published private(set) var preparingNow = false

    private let builder: DigestBuilder
    private let queue: InferenceQueue
    private let settings: AppSettings
    private var context: () -> Context? = { nil }
    /// Recording, transcription, lock and power state (the scheduler adds the
    /// model, the user's pause, "Prepare now" and failures itself).
    private var activity: () -> DigestActivity = { DigestActivity() }

    private var work: [DigestSchedulePolicy.Candidate] = []
    private var patientsByID: [UUID: Patient] = [:]
    private var sessionsByID: [UUID: SessionRecord] = [:]
    private var needsScan = true
    private var nextScanAt = Date.distantPast
    private var lastFailure: Date?
    private var wasLocked = false
    private var firstSession: UUID?
    private var firstPatient: UUID?
    private var buildingSessionID: UUID?
    private var loop: Task<Void, Never>?
    /// Tells the current loop apart from one that was stopped and replaced.
    private var loopID = UUID()
    private var scanning: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var watchers: [AnyCancellable] = []

    /// The clock for the scan interval and failure back-off.
    private let now: () -> Date

    init(builder: DigestBuilder, queue: InferenceQueue, settings: AppSettings, now: @escaping () -> Date = Date.init) {
        self.builder = builder
        self.queue = queue
        self.settings = settings
        self.now = now
    }

    /// Connects the scheduler to the app and starts it: it looks again whenever
    /// the AI queue or the settings change, and every few seconds for
    /// recording, transcription, the lock and power. Stops when the app quits.
    func attach(context: @escaping () -> Context?, activity: @escaping () -> DigestActivity) {
        self.context = context
        self.activity = activity
        watchers = [
            queue.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            },
            settings.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            },
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
        ]
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let scheduler = self else { return }
                scheduler.evaluate()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Stops everything (quitting). Finished sections stay on disk for next time.
    func stop() {
        poller?.cancel()
        poller = nil
        watchers = []
        scanning?.cancel()
        scanning = nil
        halt()
    }

    // MARK: - Requests from the screens

    /// A session was opened: if it needs a summary and has none, it goes first.
    /// Its patient is looked at again (it may have a new or edited transcript).
    func sessionOpened(patient: Patient, session: SessionRecord) {
        firstSession = session.id
        patientOpened(patient)
    }

    /// Try again now after a failed build (the session's Retry): no waiting out the pause after a failure.
    func retry(patient: Patient, session: SessionRecord) {
        lastFailure = nil
        builder.cancel(session.id)
        sessionOpened(patient: patient, session: session)
    }

    /// A transcript was saved (recorded, transcribed or edited): its patient
    /// is looked at again, and the session goes first if it needs a summary.
    func transcriptSaved(patient: Patient, session: SessionRecord) {
        sessionOpened(patient: patient, session: session)
    }

    /// The patient's page or chat is open: their sessions go first, and their
    /// sessions are looked at again (one patient, not the whole library).
    func patientOpened(_ patient: Patient) {
        firstPatient = patient.id
        reorder()
        guard let ctx = context() else { return }
        let store = ctx.store
        let room = ctx.service.budget.availableCharacters(reserving: DigestSchedulePolicy.promptOverhead)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                DigestScheduler.scanSessions(store: store, patients: [patient], room: room)
            }.value
            self?.merge(result, patient: patient.id)
            self?.evaluate()
        }
    }

    func perform(_ action: DigestSchedulePolicy.Action, patientID: UUID) {
        switch action {
        case .pause:
            settings.summariesPaused = true
            preparingNow = false
        case .resume:
            settings.summariesPaused = false
        case .prepareNow:
            preparingNow = true
            lastFailure = nil
            firstPatient = patientID
            reorder()
        }
        evaluate()
    }

    /// The status line and control for one patient; nil when it needs no summaries.
    func status(for patientID: UUID) -> (text: String, action: DigestSchedulePolicy.Action?)? {
        guard let count = counts[patientID] else { return nil }
        return DigestSchedulePolicy.status(
            ready: count.ready, needed: count.needed, pause: pauseReason, building: buildingPatientID == patientID)
    }

    // MARK: - Running

    /// Looks at what else is going on: looks for work when it is time to,
    /// pauses (stopping a build in progress) or starts building.
    func evaluate() {
        var now = activity()
        now.userPaused = settings.summariesPaused
        // The setting lifts only the battery pause; Low Power Mode still pauses.
        if settings.prepareSummariesOnBattery { now.onBattery = false }
        now.preparingNow = preparingNow
        now.recentFailure = lastFailure.map { self.now().timeIntervalSince($0) < DigestSchedulePolicy.failureBackoff } ?? false
        let running = queue.running.map { $0.kind != .digest } ?? false
        now.modelBusy = running || queue.waiting.contains { $0.kind != .digest }
        if wasLocked && !now.locked { needsScan = true }
        wasLocked = now.locked

        let reason = DigestSchedulePolicy.pauseReason(now)
        if pauseReason != reason { pauseReason = reason }

        // Looking for work reads and decrypts transcripts but asks nothing of the
        // model, so it runs even while paused, except while locked, recording or transcribing.
        let mayScan = !now.locked && !now.recording && !now.transcribing
        if mayScan, scanning == nil, needsScan || (work.isEmpty && loop == nil && self.now() >= nextScanAt) {
            startScan()
        }
        if reason != nil {
            halt()
            return
        }
        guard loop == nil, scanning == nil, !work.isEmpty else { return }
        let id = UUID()
        loopID = id
        loop = Task { [weak self] in
            await self?.run(id: id)
        }
    }

    private func startScan() {
        guard let ctx = context() else { return }
        needsScan = false
        let store = ctx.store
        let patients = ctx.patients
        let room = ctx.service.budget.availableCharacters(reserving: DigestSchedulePolicy.promptOverhead)
        scanning = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                DigestScheduler.scanSessions(store: store, patients: patients, room: room)
            }.value
            guard let self else { return }
            self.scanning = nil
            self.apply(result)
            if self.work.isEmpty {
                self.preparingNow = false
                self.nextScanAt = self.now().addingTimeInterval(DigestSchedulePolicy.rescanInterval)
            }
            self.evaluate()
        }
    }

    /// Stops the build loop and the build in progress; that session is first next time.
    private func halt() {
        loop?.cancel()
        loop = nil
        loopID = UUID()
        if let id = buildingSessionID {
            builder.cancel(id)
        }
    }

    private func run(id: UUID) async {
        defer {
            if loopID == id {
                loop = nil
                buildingSessionID = nil
                buildingPatientID = nil
            }
        }
        while !Task.isCancelled, loopID == id {
            guard let ctx = context() else { return }
            guard let next = work.first else {
                // Everything that needs a summary has one; look again later.
                preparingNow = false
                nextScanAt = self.now().addingTimeInterval(DigestSchedulePolicy.rescanInterval)
                return
            }
            guard let patient = patientsByID[next.patientID], let session = sessionsByID[next.sessionID] else {
                work.removeFirst()
                continue
            }
            let store = ctx.store
            let transcript = await Task.detached(priority: .utility) {
                (try? store.readTranscript(for: patient, session: session)) ?? nil
            }.value
            if Task.isCancelled { return }
            var service = ctx.service
            service.clientName = patient.name
            guard let transcript, !transcript.isEmpty,
                  let build = builder.ensureDigest(
                    for: patient, session: session, transcript: transcript, store: store, service: service)
            else {
                // No transcript any more, or a note is building this one itself.
                work.removeAll { $0.sessionID == session.id }
                continue
            }
            buildingSessionID = session.id
            buildingPatientID = patient.id
            await build.value
            buildingSessionID = nil
            buildingPatientID = nil
            // Paused part-way: this session stays first, its finished sections kept.
            if Task.isCancelled { return }
            work.removeAll { $0.sessionID == session.id }
            if builder.failures[session.id] != nil {
                // Try again after a pause; this one goes last.
                work.append(next)
                lastFailure = self.now()
                evaluate()
                return
            }
            if var count = counts[patient.id] {
                count.ready = min(count.needed, count.ready + 1)
                counts[patient.id] = count
            }
        }
    }

    private func apply(_ result: ScanResult) {
        patientsByID = result.patients
        sessionsByID = result.sessions
        counts = result.counts
        work = result.work
        reorder()
    }

    /// One patient looked at again: their counts and waiting sessions replaced.
    private func merge(_ result: ScanResult, patient: UUID) {
        if let found = result.patients[patient] { patientsByID[patient] = found }
        for (id, session) in result.sessions { sessionsByID[id] = session }
        counts[patient] = result.counts[patient]
        work.removeAll { $0.patientID == patient && $0.sessionID != buildingSessionID }
        for item in result.work where !work.contains(item) { work.append(item) }
        reorder()
    }

    private func reorder() {
        work = DigestSchedulePolicy.order(work, session: firstSession, patient: firstPatient)
    }

    struct ScanResult {
        var patients: [UUID: Patient] = [:]
        var sessions: [UUID: SessionRecord] = [:]
        var counts: [UUID: Count] = [:]
        var work: [DigestSchedulePolicy.Candidate] = []
    }

    /// Which sessions of `patients` need a summary and which have one (from any
    /// model: the text is about the same transcript). No model calls.
    nonisolated static func scanSessions(store: Store, patients: [Patient], room: Int) -> ScanResult {
        var result = ScanResult()
        for patient in patients {
            if Task.isCancelled { break }
            result.patients[patient.id] = patient
            let sessions = (try? store.listSessions(for: patient)) ?? []
            var items: [(session: SessionRecord, characters: Int, readsWhole: Bool, ready: Bool)] = []
            var history = 0
            for session in sessions {
                guard let read = try? store.readTranscript(for: patient, session: session),
                      !read.isEmpty else { continue }
                let ready = store.anyCurrentDigest(for: patient, session: session, transcript: read) != nil
                items.append((session, read.count, LongSessionNote.readsWhole(read), ready))
                history += read.count
            }
            var count = Count(ready: 0, needed: 0)
            for item in items where DigestSchedulePolicy.needsSummary(
                transcriptCharacters: item.characters, historyCharacters: history, room: room,
                readsWhole: item.readsWhole
            ) {
                count.needed += 1
                if item.ready {
                    count.ready += 1
                } else {
                    result.sessions[item.session.id] = item.session
                    result.work.append(.init(patientID: patient.id, sessionID: item.session.id, date: item.session.date))
                }
            }
            if count.needed > 0 { result.counts[patient.id] = count }
        }
        return result
    }
}

extension DigestScheduler: ShutdownJob {
    /// The summary being built, so it goes first next launch. (Every other
    /// session that still needs one is found again by the launch scan.)
    func interruptedWork() -> [InterruptedWork] {
        guard let id = buildingSessionID, let session = sessionsByID[id] else { return [] }
        return [InterruptedWork(kind: .digest, patientID: session.patientId, sessionFolder: session.folderName)]
    }

    /// Cancels the build loop and the build in progress, and waits for the
    /// loop to return (it waits on the build, whose model calls are queue jobs
    /// the queue's own shutdown cancels).
    func shutDown() async {
        let running = loop
        stop()
        await running?.value
    }
}
