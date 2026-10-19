import Foundation

enum ResourceReuse {
    /// A prior success is a reason to recheck, never permission to upload again
    /// after an ambiguous miss. Match actual content rather than a file name.
    static func evidence(for job: BackupJob, history: [BackupJob]) -> [String: String] {
        var result: [String: String] = [:]
        let candidates = history.filter {
            $0.id != job.id && $0.account == job.account && $0.state == .completed &&
            $0.standardConfirmationPassed && $0.settings.quality == job.settings.quality &&
            (!$0.isLive || $0.settings.live == job.settings.live)
        }
        for resource in job.resources where !resource.sha1.isEmpty && !resource.sha256.isEmpty && resource.size > 0 {
            if let match = candidates.flatMap(\.resources).first(where: {
                $0.confirmed && !$0.remoteKey.isEmpty && $0.sha1 == resource.sha1 &&
                $0.sha256 == resource.sha256 && $0.size == resource.size
            }) { result[resource.id] = match.remoteKey }
        }
        return result
    }
}
