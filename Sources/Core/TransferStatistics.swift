import Foundation

struct UploadProgressSample {
    var taskID: Int
    var jobID: String
    var resourceID: String
    var sent: Int64
    var total: Int64
    var time: TimeInterval
}

/// In-memory, monotonic-clock measurements. Parallel uploads contribute bytes
/// to one moving window, rather than adding per-file rates (which overcounts
/// short sequential files). Never persists identifiers or measurements.
struct TransferRateTracker {
    private var streams: [Int: UploadProgressSample] = [:]
    private var events: [(time: TimeInterval, bytes: Double)] = []
    private var bytes: Double = 0
    private var lastData = -Double.infinity

    mutating func record(_ sample: UploadProgressSample) {
        guard sample.total > 0, sample.sent >= 0, sample.time.isFinite else { return }
        let previous = streams[sample.taskID]
        if let previous, sample.time < previous.time { return }
        streams[sample.taskID] = sample
        if let last = events.last, sample.time - last.time > 8 {
            events = [(sample.time, bytes)]; lastData = -Double.infinity
            return
        }
        if events.isEmpty { events.append((sample.time, bytes)) }
        guard let previous, previous.jobID == sample.jobID, previous.resourceID == sample.resourceID,
              sample.time - previous.time <= 8, sample.total == previous.total, sample.sent >= previous.sent else { return }
        let delta = min(sample.sent, sample.total) - min(previous.sent, previous.total)
        guard delta > 0 else { return }
        bytes += Double(delta); lastData = sample.time
        events.append((sample.time, bytes))
        while events.count > 2 && events[1].time <= sample.time - 8 { events.removeFirst() }
        if events.count > 128 { events.removeFirst(events.count - 128) }
    }
    mutating func finish(_ taskID: Int) { streams.removeValue(forKey: taskID) }
    func sent(_ taskID: Int?) -> Int64 {
        guard let taskID else { return 0 }
        return streams[taskID]?.sent ?? 0
    }
    func speed(now: TimeInterval, active: Set<Int>) -> Double? {
        guard !active.isEmpty else { return 0 }
        guard let first = events.first else { return nil }
        guard now >= first.time, now - first.time >= 1 else { return nil }
        guard now - lastData <= 3 else { return 0 }
        let anchor = events.last(where: { $0.time <= now - 8 }) ?? first
        let elapsed = now - anchor.time
        return elapsed > 0 ? max(0, (bytes - anchor.bytes) / elapsed) : nil
    }
}

struct BackupTransferSummary {
    var bytesPerSecond: Double?
    var remainingBytes: Int64
    var unknownSizeCount: Int
    var uploadFinished: Bool { unknownSizeCount == 0 && remainingBytes == 0 }
}

/// Cache manifests on task changes. Count only measured bytes; unprepared
/// assets stay explicitly unknown instead of borrowing another asset's size.
struct UploadWorkload {
    private struct Part { var size: Int64; var taskID: Int? }
    private var parts: [Part] = []
    private var unknownSizeCount = 0
    private var active = Set<Int>()

    init(jobs: [BackupJob], account: String) {
        let pending: Set<JobState> = [.queued, .preparing, .transferring, .committing, .confirming, .paired, .waiting]
        for job in jobs where job.account == account && job.activityHidden != true && pending.contains(job.state) {
            guard !job.resources.isEmpty, job.resources.allSatisfy({ $0.size > 0 }) else {
                unknownSizeCount += 1; continue
            }
            for resource in job.resources where !resource.confirmed && !resource.submitted && resource.responsePath == nil {
                parts.append(Part(size: resource.size, taskID: resource.transportID))
                if job.state == .transferring, let id = resource.transportID { active.insert(id) }
            }
        }
    }
    func summary(tracker: TransferRateTracker, now: TimeInterval, canTransfer: Bool) -> BackupTransferSummary {
        let remaining = parts.reduce(Int64(0)) { result, part in
            let bytes = part.size - max(0, min(part.size, tracker.sent(part.taskID)))
            let sum = result.addingReportingOverflow(bytes)
            return sum.overflow ? Int64.max : sum.partialValue
        }
        let speed = canTransfer ? tracker.speed(now: now, active: active) : 0
        return BackupTransferSummary(bytesPerSecond: speed, remainingBytes: remaining, unknownSizeCount: unknownSizeCount)
    }
}
