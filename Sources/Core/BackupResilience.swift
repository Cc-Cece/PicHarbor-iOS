import Foundation

struct BackupExecutionPolicy: Codable, Equatable {
    var retries = 3
    var querySeconds = 60
    var commitSeconds = 90
    var idleSeconds = 120
    var fileMinutes = 120
    var cloudMinutes = 60
    var valid: Bool {
        (0...10).contains(retries) && (15...300).contains(querySeconds) && (15...600).contains(commitSeconds) &&
        (30...1800).contains(idleSeconds) && (10...1440).contains(fileMinutes) && (10...240).contains(cloudMinutes)
    }
    func fileSeconds(size: Int64) -> Double {
        min(Double(fileMinutes * 60), max(600, 300 + Double(max(0, size)) / (64 * 1024)))
    }
    func stageSeconds(_ stage: PipelineStage) -> Double {
        stage == .preparation ? Double(fileMinutes * 60) : Double(stage == .commit ? commitSeconds : querySeconds)
    }
}

/// Monotonic events, rather than a stage name or database generation, define
/// progress. Retrying an invalid receipt cannot reset its own retry allowance.
struct BackupRecoveryBudget: Codable {
    var events = Set<String>()
    var failures = 0
    var activeWithoutProgress: Double = 0
    var handoffs = 0
    var cloudSeconds: Double = 0
    mutating func observe(_ current: Set<String>) {
        guard !current.isSubset(of: events) else { return }
        events.formUnion(current)
        failures = 0; activeWithoutProgress = 0; handoffs = 0; cloudSeconds = 0
    }
    mutating func failure(policy: BackupExecutionPolicy) -> Bool {
        failures += 1
        return failures <= policy.retries
    }
    var retryDelay: Double { min(120, 5 * pow(2, Double(min(failures, 5)))) }
    func stalled(policy: BackupExecutionPolicy) -> Bool {
        handoffs >= 32 || activeWithoutProgress >= Double(policy.idleSeconds)
    }
}

extension BackupSettings {
    var executionPolicy: BackupExecutionPolicy {
        executionOverrides?.valid == true ? executionOverrides! : BackupExecutionPolicy()
    }
}

extension BackupJob {
    var recoveryEvents: Set<String> {
        var events = Set<String>()
        for value in resources {
            events.insert(value.id + ":prepared")
            if value.responsePath != nil { events.insert(value.id + ":receipt") }
            if value.submitted { events.insert(value.id + ":submitted") }
            if !value.remoteKey.isEmpty { events.insert(value.id + ":key") }
            if value.confirmed { events.insert(value.id + ":confirmed") }
        }
        for value in livePairs ?? [] {
            if value.submitted { events.insert(value.id + ":pair_submitted") }
            if value.isConfirmed(in: resources) { events.insert(value.id + ":pair_confirmed") }
        }
        if albumsPending { events.insert("albums_pending") }
        return events
    }
    var awaitingCloud: Bool {
        error == "PAIR_CONFIRMATION_PENDING" || error == "REMOTE_NOT_VISIBLE" ||
        (error.hasPrefix("REMOTE_MOTION_") && error != "REMOTE_MOTION_TRASHED")
    }
    mutating func observeRecoveryProgress() {
        var value = recovery ?? BackupRecoveryBudget()
        value.observe(recoveryEvents); recovery = value
    }
    mutating func retryFailure(_ code: String, policy: BackupExecutionPolicy, now: Date = Date()) {
        observeRecoveryProgress()
        var budget = recovery!
        let retry = budget.failure(policy: policy)
        recovery = budget; lastAttemptError = code
        error = retry ? code : "RETRY_LIMIT"
        state = retry ? .waiting : .attention
        retryAt = retry ? now.addingTimeInterval(budget.retryDelay) : nil
    }
    mutating func resetRecoveryAllowance() {
        recovery = BackupRecoveryBudget(events: recoveryEvents)
        lastAttemptError = nil
    }
}

/// A thread-safe cooperative lease. Cancellation callbacks only target this
/// attempt's request IDs. A lane is released after the actual worker unwinds.
final class BackupExecutionLease: @unchecked Sendable {
    let policy: BackupExecutionPolicy
    let stage: PipelineStage
    private let lock = NSLock()
    private var elapsed: Double = 0, idle: Double = 0
    private var checkpointElapsed: Double = 0
    private var callbacks: [String: (String) -> Void] = [:]
    private var reason: String?
    init(stage: PipelineStage, policy: BackupExecutionPolicy) { self.stage = stage; self.policy = policy }
    var cancellation: String? { lock.lock(); defer { lock.unlock() }; return reason }
    var activeSeconds: Double { lock.lock(); defer { lock.unlock() }; return elapsed }
    var checkpointSeconds: Double { lock.lock(); defer { lock.unlock() }; return checkpointElapsed }
    var remaining: Double { lock.lock(); defer { lock.unlock() }; return max(.01, policy.stageSeconds(stage) - elapsed) }
    func check() throws { if let code = cancellation { throw HarborError(code) } }
    func progress() { lock.lock(); idle = 0; lock.unlock() }
    func checkpoint() { lock.lock(); checkpointElapsed = 0; idle = 0; lock.unlock() }
    func tick(_ seconds: Double) {
        // A long scheduling gap is a suspended app, not active execution.
        guard seconds >= 0, seconds <= 15 else { return }
        lock.lock(); elapsed += seconds; idle += seconds; checkpointElapsed += seconds
        let code: String? = elapsed >= policy.stageSeconds(stage) ? "STAGE_TIMEOUT" :
            (stage == .preparation && idle >= Double(policy.idleSeconds) ? "NO_PROGRESS_TIMEOUT" : nil)
        lock.unlock()
        if let code { cancel(code) }
    }
    func register(_ id: String, cancel: @escaping (String) -> Void) {
        lock.lock(); callbacks[id] = cancel; let code = reason; lock.unlock()
        if let code { cancel(code) }
    }
    func unregister(_ id: String) { lock.lock(); callbacks.removeValue(forKey: id); lock.unlock() }
    func cancel(_ code: String) {
        lock.lock()
        guard reason == nil else { lock.unlock(); return }
        reason = code; let callbacks = Array(callbacks.values); lock.unlock()
        for callback in callbacks { callback(code) }
    }
}

enum BackupExecutionContext {
    @TaskLocal static var lease: BackupExecutionLease?
}

/// Counts only observed, connected foreground intervals. Relaunch, suspension,
/// a paused task or a network wait cannot spend hours of a cloud wait budget.
struct BackupObservedClock {
    private var previous: Double?
    mutating func tick(now: Double, running: Bool) -> Double {
        defer { previous = running ? now : nil }
        guard running, let previous else { return 0 }
        let delta = now - previous
        return delta >= 0 && delta <= 15 ? delta : 0
    }
}

struct BackupTransferWatch: Codable {
    var taskID: Int
    var resourceID: String
    var policy: BackupExecutionPolicy
    var sent: Int64 = 0
    var active: Double = 0
    var idle: Double = 0
    mutating func progress(_ bytes: Int64) {
        if bytes > sent { sent = bytes; idle = 0 }
    }
    mutating func tick(_ seconds: Double, size: Int64) -> String? {
        active += seconds; idle += seconds
        if idle >= Double(policy.idleSeconds) { return "NO_PROGRESS_TIMEOUT" }
        if active >= policy.fileSeconds(size: size) { return "TRANSFER_TIMEOUT" }
        return nil
    }
}
