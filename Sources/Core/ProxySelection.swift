import Foundation

actor ProxyProbeLimiter {
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 3 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }
    }
}

enum ProxySelection: String, Codable, CaseIterable, Identifiable {
    case manual, automatic
    var id: String { rawValue }
    var title: String { self == .manual ? L10n.text("手动选择") : L10n.text("自动选择") }
}
enum ProxyExhaustion: String, Codable, CaseIterable, Identifiable {
    case wait, direct
    var id: String { rawValue }
    var title: String { self == .wait ? L10n.text("暂停等待") : L10n.text("允许直连") }
}
struct ProxyPolicy: Codable, Equatable {
    var selection: ProxySelection = .manual
    var exhaustion: ProxyExhaustion = .wait
    var primary = ""
    var backups: [String] = []
    static func resolve(_ preferences: ProxyPreferences, legacy: ProxyFallback? = nil, override: ProxyPolicy? = nil) -> ProxyPolicy {
        if let override { return override }
        if let legacy {
            return ProxyPolicy(exhaustion: legacy == .direct ? .direct : .wait, primary: preferences.primary,
                               backups: legacy == .wait ? [] : preferences.backups)
        }
        return ProxyPolicy(selection: preferences.selection ?? .manual,
                           exhaustion: preferences.exhaustion ?? (preferences.fallback == .direct ? .direct : .wait),
                           primary: preferences.primary,
                           backups: preferences.selection == nil && preferences.fallback == .wait ? [] : preferences.backups)
    }
}
struct ProxyNodeHealth: Equatable {
    var measuredAt: Date?
    var milliseconds: Int?
    var lastSuccess: Date?
    var lastFailure: Date?
    var failures = 0
    var coolingUntil: Date?
    func cooling(at now: Date) -> Bool { (coolingUntil ?? .distantPast) > now }
    func healthy(at now: Date) -> Bool {
        !cooling(at: now) && lastSuccess != nil && lastSuccess! > (lastFailure ?? .distantPast) && now.timeIntervalSince(lastSuccess!) < 300
    }
    mutating func succeed(at now: Date) { lastSuccess = now; coolingUntil = nil }
    mutating func fail(at now: Date) {
        if now.timeIntervalSince(lastFailure ?? .distantPast) >= 300 { failures = 0 }
        lastFailure = now; failures = min(8, failures + 1)
        coolingUntil = now.addingTimeInterval(min(120, 15 * pow(2, Double(failures - 1))))
    }
    func penalty(at now: Date) -> Int { now.timeIntervalSince(lastFailure ?? .distantPast) < 300 ? failures * 500 : 0 }
    mutating func recordMeasurement(_ milliseconds: Int?, began: Date, now: Date) {
        measuredAt = now; self.milliseconds = milliseconds
        if milliseconds != nil {
            if (lastFailure ?? .distantPast) <= began { succeed(at: now) }
        } else if (lastSuccess ?? .distantPast) <= began { fail(at: now) }
    }
}
enum ProxyNodeRanking {
    static func ordered(names: [String], health: [String: ProxyNodeHealth], preferred: String?, failures: [String], now: Date) -> [String] {
        let allowed = names.filter { !failures.contains($0) && !(health[$0]?.cooling(at: now) ?? false) }
        let ranked = allowed.sorted { a, b in
            let left = health[a], right = health[b]
            let lh = left?.healthy(at: now) ?? false, rh = right?.healthy(at: now) ?? false
            if lh != rh { return lh }
            let ls = (left?.milliseconds ?? 100_000) + (left?.penalty(at: now) ?? 0)
            let rs = (right?.milliseconds ?? 100_000) + (right?.penalty(at: now) ?? 0)
            return ls == rs ? (names.firstIndex(of: a) ?? 0) < (names.firstIndex(of: b) ?? 0) : ls < rs
        }
        if let preferred, allowed.contains(preferred), health[preferred]?.healthy(at: now) == true {
            return [preferred] + ranked.filter { $0 != preferred }
        }
        return ranked
    }
}
