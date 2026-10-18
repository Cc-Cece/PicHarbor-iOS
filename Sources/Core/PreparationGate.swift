import Foundation

/// Export and mux one logical asset at a time; uploads remain independently concurrent.
actor PreparationGate {
    static let shared = PreparationGate()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { locked = false }
        else { waiters.removeFirst().resume() }
    }
}
