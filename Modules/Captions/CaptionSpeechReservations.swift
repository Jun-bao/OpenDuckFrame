import Foundation

/// App-local ownership above AssetInventory, whose reservations are not reference
/// counted and may use a different regional locale from the one requested.
/// Every Speech user in this module must acquire here before touching assets.
actor CaptionSpeechReservations {
    struct Backend: Sendable {
        let reserved: @Sendable () async -> [Locale]
        let reserve: @Sendable (Locale) async throws -> Bool
        let release: @Sendable (Locale) async -> Void
    }
    struct Lease: Sendable { fileprivate let id: UUID }
    private struct Owned {
        let locale: Locale
        var users: Int
    }
    private let backend: Backend
    private var owned: [String: Owned] = [:]
    private var aliases: [String: Set<String>] = [:]
    private var leases: [UUID: Set<String>] = [:]
    private var changing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(backend: Backend) { self.backend = backend }

    // Actor reentrancy alone does not serialize the before/reserve/after operation.
    // This gate is suspended, never a blocking lock on a playback or main thread.
    private func enter() async {
        if !changing { changing = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func leave() {
        if waiters.isEmpty { changing = false }
        else { waiters.removeFirst().resume() }
    }

    func acquire(_ locale: Locale) async throws -> Lease {
        try Task.checkCancellation()
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        let before = Set(await backend.reserved().map(\.identifier))
        let created = try await backend.reserve(locale)
        let after = await backend.reserved()
        let added = Set(after.filter { !before.contains($0.identifier) }.map(\.identifier))
        if created {
            for actual in after where added.contains(actual.identifier) {
                owned[actual.identifier] = Owned(locale: actual, users: 0)
            }
            aliases[locale.identifier] = added
        }
        let known = Set(owned.keys)
        let protected: Set<String>
        if let mapped = aliases[locale.identifier] {
            protected = mapped.intersection(known)
        } else if known.contains(locale.identifier) {
            protected = [locale.identifier]
        } else {
            // reserve(false) can mean an unobserved alias of an owned locale.
            // Protect all possible owned assets until this borrower exits; never
            // claim or release reservations created outside this module.
            protected = before.intersection(known)
        }
        for key in protected { owned[key]!.users += 1 }
        let lease = Lease(id: UUID())
        leases[lease.id] = protected
        return lease
    }

    /// Idempotent and deliberately completes even when its caller is cancelled.
    func release(_ lease: Lease) async {
        await enter()
        defer { leave() }
        guard let held = leases.removeValue(forKey: lease.id) else { return }
        for key in held {
            guard var entry = owned[key] else { continue }
            entry.users -= 1
            if entry.users == 0 {
                owned.removeValue(forKey: key)
                await backend.release(entry.locale)
            } else {
                owned[key] = entry
            }
        }
        aliases = aliases.filter { !$0.value.isDisjoint(with: Set(owned.keys)) }
    }
}
