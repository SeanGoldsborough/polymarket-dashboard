//
//  BondStore.swift
//  PocketTrackpad
//
//  Persistence for the Connection tab's device list.
//
//  WHAT THIS IS NOT
//  ----------------
//  This is NOT a bond store in the Bluetooth sense. The actual bonding material —
//  the Long Term Key, the IRK that lets us recognise a Mac behind a resolvable
//  private address, the CSRK — is generated and held by iOS's Bluetooth daemon.
//  There is no CoreBluetooth API to enumerate bonds, inspect them, or delete
//  them; the peripheral role does not even get told when bonding completes. What
//  this class stores is the human layer on top: which centrals we have seen,
//  what they call themselves, when they last connected, and which
//  `ReportTopology` actually worked for each one (which is the genuinely valuable
//  bit — it lets `start(topology:)` open with the candidate that worked last time
//  instead of walking the list from the top on every launch).
//
//  Consequently `remove(_:)` is COSMETIC. It deletes our note about the device.
//  iOS keeps the bond, macOS keeps its half of it, and the two will happily
//  reconnect without prompting. A user who genuinely wants to unpair must do it
//  on the Mac, in System Settings > Bluetooth > (device) > Forget, and — if iOS
//  is holding a stale bond — in Settings > Bluetooth on the phone. The UI must
//  say so; a "Forget" button that appears to work and does not is worse than no
//  button. `KnownCentral.id` is the `CBCentral.identifier`, which is itself only
//  stable for as long as iOS keeps the pairing, so an entry that stops matching
//  is a symptom of the Mac having forgotten us, not of this store losing data.
//

import Foundation

/// Codable persistence of `[KnownCentral]` in `UserDefaults`.
///
/// Not actor-isolated, and `@unchecked Sendable` rather than isolated:
///
///  * Isolating it to the main actor would make it awkward to use from
///    `XCTestCase` methods and would buy nothing — there is no state here to
///    protect.
///  * The only stored properties are two immutable `let`s. `UserDefaults` is
///    documented as thread-safe, and every read-modify-write below goes through
///    it. The "unchecked" part is therefore a claim about `UserDefaults`, not
///    about this class.
///  * `JSONEncoder`/`JSONDecoder` are NOT Sendable and are deliberately created
///    per call rather than stored. They cost microseconds against a list capped
///    at 32 entries that is touched once per connection, so keeping the type
///    trivially Sendable is worth more than the allocation.
///
/// The read-modify-write pairs (`add`, `touch`, `remove`) are not atomic across
/// processes. They do not need to be: only this app writes this key, and only
/// from the main actor in practice.
public final class BondStore: @unchecked Sendable {

    /// Default storage key. Namespaced so a future migration can leave it behind.
    public static let defaultKey = "hid.knownCentrals.v1"

    private let defaults: UserDefaults
    private let key: String

    /// - Parameters:
    ///   - defaults: injectable so tests can use
    ///     `UserDefaults(suiteName: UUID().uuidString)` and stay isolated from the
    ///     real app domain and from each other.
    ///   - key: injectable for the same reason.
    public init(defaults: UserDefaults = .standard, key: String = BondStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    // MARK: Read

    /// Everything we remember, most recently seen first.
    ///
    /// A decode failure returns an empty list rather than throwing. The stored
    /// value is a convenience cache, not user data: if a future build changes
    /// `KnownCentral`'s shape, silently starting over is correct, whereas
    /// propagating a decode error would block the Connection tab from loading at
    /// all over a list that rebuilds itself on the next connection.
    public func all() -> [KnownCentral] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([KnownCentral].self, from: data) else {
            defaults.removeObject(forKey: key)
            return []
        }
        return decoded.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// The remembered entry for a central, if any.
    public func central(with id: UUID) -> KnownCentral? {
        all().first { $0.id == id }
    }

    /// The topology that last worked for this central, if we know one.
    public func workingTopology(for id: UUID) -> ReportTopology? {
        central(with: id)?.workingTopology
    }

    // MARK: Write

    /// Insert or replace by `id`.
    public func add(_ central: KnownCentral) {
        var list = all().filter { $0.id != central.id }
        list.append(central)
        persist(list)
    }

    /// Record that we just heard from this central.
    ///
    /// `name` and `topology` are optional so a caller with partial information
    /// does not overwrite good data with nil — a `didSubscribeTo` callback knows
    /// the identifier but often not a useful name, and clobbering the name the
    /// user recognises with "Unknown" every reconnection is a real bug this
    /// signature prevents.
    public func touch(id: UUID, name: String? = nil, workingTopology: ReportTopology? = nil, at date: Date = .now) {
        var list = all()
        if let index = list.firstIndex(where: { $0.id == id }) {
            var entry = list[index]
            entry.lastSeen = date
            if let name, !name.isEmpty { entry.name = name }
            if let workingTopology { entry.workingTopology = workingTopology }
            list[index] = entry
        } else {
            // CoreBluetooth's peripheral role never tells us the central's name
            // (see `HIDPeripheralManager.rememberCentral`), so a first sighting
            // usually lands here with `name == nil`.
            let resolvedName: String
            if let name, !name.isEmpty {
                resolvedName = name
            } else {
                resolvedName = "Unknown Mac"
            }
            list.append(
                KnownCentral(
                    id: id,
                    name: resolvedName,
                    lastSeen: date,
                    workingTopology: workingTopology
                )
            )
        }
        persist(list)
    }

    /// Forget our note about a central. See the file header: this does not
    /// unpair anything.
    public func remove(id: UUID) {
        persist(all().filter { $0.id != id })
    }

    /// Convenience overload matching `HIDPeripheralControlling.forget(_:)`.
    public func remove(_ central: KnownCentral) {
        remove(id: central.id)
    }

    /// Forget everything. Same caveat.
    public func removeAll() {
        defaults.removeObject(forKey: key)
    }

    // MARK: Private

    private func persist(_ list: [KnownCentral]) {
        // Bound the list. Each entry is tiny, but UserDefaults is loaded eagerly at
        // launch and an unbounded list of one-off centrals from a busy office is
        // pure launch-time cost for data nobody will read.
        let trimmed = Array(list.sorted { $0.lastSeen > $1.lastSeen }.prefix(32))
        guard let data = try? JSONEncoder().encode(trimmed) else {
            // `KnownCentral` is a plain Codable struct of UUID/String/Date/enum, so
            // this cannot fail in practice. Failing silently is still the right
            // call: the alternative is crashing the radio layer over a cache.
            return
        }
        defaults.set(data, forKey: key)
    }
}
