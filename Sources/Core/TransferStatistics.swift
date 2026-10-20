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
    var remainingSeconds: Double?
    var uploadFinished: Bool
}

/// Cache this on task changes, not progress callbacks. Unknown assets are
/// estimated only from known sizes with the same media kind and backup policy.
struct UploadWorkload {
    private struct Part { var size: Int64; var taskID: Int? }
    private var parts: [Part] = []
    private var estimatedBytes: Double = 0
    private var hasUnknownSize = false
    private var active = Set<Int>()

    init(jobs: [BackupJob], account: String) {
        var samples: [String: (bytes: Double, count: Int)] = [:]
        var unknown: [String: Int] = [:]
        let pending: Set<JobState> = [.queued, .preparing, .transferring, .committing, .confirming, .paired, .waiting]
        for job in jobs where job.account == account && job.activityHidden != true && job.state != .cancelled {
            let kind = job.isLive ? "live" : job.mediaKind == "video" ? "video" : "photo"
            let key = kind + "|" + job.settings.mediaPolicy
            let known = !job.resources.isEmpty && job.resources.allSatisfy { $0.size > 0 }
            if known {
                let size = job.resources.reduce(0.0) { $0 + Double($1.size) }
                let previous = samples[key] ?? (0, 0)
                samples[key] = (previous.bytes + size, previous.count + 1)
            }
            guard pending.contains(job.state) else { continue }
            if !known { unknown[key, default: 0] += 1; continue }
            for resource in job.resources where !resource.confirmed && !resource.submitted && resource.responsePath == nil {
                parts.append(Part(size: resource.size, taskID: resource.transportID))
                if job.state == .transferring, let id = resource.transportID { active.insert(id) }
            }
        }
        for (key, count) in unknown {
            if let sample = samples[key], sample.count > 0 {
                estimatedBytes += sample.bytes / Double(sample.count) * Double(count)
            } else { hasUnknownSize = true }
        }
    }
    func summary(tracker: TransferRateTracker, now: TimeInterval, canTransfer: Bool) -> BackupTransferSummary {
        let remaining = parts.reduce(estimatedBytes) { result, part in
            result + Double(max(0, part.size - max(0, min(part.size, tracker.sent(part.taskID)))))
        }
        let speed = canTransfer ? tracker.speed(now: now, active: active) : 0
        let seconds: Double?
        if !hasUnknownSize, remaining > 0, let speed, speed > 0 { seconds = remaining / speed }
        else { seconds = nil }
        return BackupTransferSummary(bytesPerSecond: speed, remainingSeconds: seconds, uploadFinished: !hasUnknownSize && remaining == 0)
    }
}
