import Foundation

enum ResourceReuse {
    /// A prior success is a reason to recheck, never permission to upload again
    /// after an ambiguous miss. Match actual content rather than a file name.
    ///
    /// This is the single local derivation of prior remote keys. The
    /// dedup *decision* is not made here: `confirmedReuseKeys` routes
    /// every candidate key through the shared core's `decide_prepare`
    /// (a `remote_key` hit means `content_exists`, skip the upload),
    /// and the pipeline still re-checks the key with `confirm_resource`
    /// before trusting it. No other call site derives prior keys.
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

    /// Core-backed reuse keys: `evidence(for:)` candidates filtered by
    /// the shared core's `decide_prepare`. A candidate the core does
    /// not confirm (`decidePrepare` false or nil) is dropped, so the
    /// pipeline uploads instead of trusting a stale local derivation.
    /// Returns nil only when the core is unavailable — the caller then
    /// treats the job as having no reusable resources rather than
    /// guessing from local history alone.
    static func confirmedReuseKeys(for job: BackupJob, history: [BackupJob],
                                   adapter: HarborCoreAdapter) async -> [String: String]? {
        guard adapter.available else { return nil }
        let derived = evidence(for: job, history: history)
        guard !derived.isEmpty else { return [:] }
        var confirmed: [String: String] = [:]
        for resource in job.resources {
            guard let key = derived[resource.id], !key.isEmpty else { continue }
            if await adapter.decidePrepare(job: job, resource: resource, remoteKey: key) == true {
                confirmed[resource.id] = key
            }
        }
        return confirmed
    }
}
