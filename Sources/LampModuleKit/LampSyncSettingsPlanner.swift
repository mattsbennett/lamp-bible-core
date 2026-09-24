/// Reconciles a settings value and identified records against the last state
/// applied by this client. The caller supplies values with local-only fields
/// and clocks removed before comparing settings.
public enum LampSyncSettingsPlanner {
    public enum MergeError: Error, Equatable {
        case concurrentSettings
        case concurrentReading
    }

    public struct Plan<ID: Hashable, Reading: Equatable> {
        public let settingsDecision: LampSyncThreeWayDecision
        public let readings: [ID: Reading]
        public let needsPublish: Bool

        public var readingIDs: Set<ID> { Set(readings.keys) }
    }

    public static func plan<Settings: Equatable, ID: Hashable, Reading: Equatable, Revision: Comparable>(
        baseSettings: Settings,
        baseReadingIDs: Set<ID>,
        localSettings: Settings,
        localReadings: [ID: Reading],
        remoteSettings: Settings,
        remoteReadings: [ID: Reading],
        revision: (Reading) -> Revision
    ) throws -> Plan<ID, Reading> {
        let settingsDecision = LampSyncThreeWayValue.decide(
            base: baseSettings,
            local: localSettings,
            remote: remoteSettings
        )
        guard settingsDecision != .conflict else { throw MergeError.concurrentSettings }

        let mergedIDs = LampSyncThreeWaySet.merge(
            base: baseReadingIDs,
            local: Set(localReadings.keys),
            remote: Set(remoteReadings.keys)
        )
        var mergedReadings: [ID: Reading] = [:]
        mergedReadings.reserveCapacity(mergedIDs.count)
        for id in mergedIDs {
            switch (localReadings[id], remoteReadings[id]) {
            case let (local?, remote?):
                let localRevision = revision(local)
                let remoteRevision = revision(remote)
                if localRevision > remoteRevision {
                    mergedReadings[id] = local
                } else if remoteRevision > localRevision {
                    mergedReadings[id] = remote
                } else if local == remote {
                    mergedReadings[id] = local
                } else {
                    throw MergeError.concurrentReading
                }
            case let (local?, nil):
                mergedReadings[id] = local
            case let (nil, remote?):
                mergedReadings[id] = remote
            case (nil, nil):
                preconditionFailure("The merged ID set contains an absent reading")
            }
        }

        return Plan(
            settingsDecision: settingsDecision,
            readings: mergedReadings,
            needsPublish: mergedReadings != remoteReadings
                || (settingsDecision == .local && localSettings != remoteSettings)
        )
    }

    /// Bootstrap an older client that has no membership baseline. Its caller
    /// must guard any pending upload against the last observed remote token.
    /// Different reading rows cannot be classified as additions or deletions
    /// without a baseline, so they must be resolved before one side publishes.
    public static func planWithoutBase<Settings: Equatable, Stamp: Comparable, ID: Hashable, Reading: Equatable>(
        localSettings: Settings,
        localRevision: Stamp,
        localReadings: [ID: Reading],
        remoteSettings: Settings,
        remoteRevision: Stamp,
        remoteReadings: [ID: Reading]
    ) throws -> Plan<ID, Reading> {
        guard localReadings == remoteReadings else { throw MergeError.concurrentReading }
        if localRevision == remoteRevision && localSettings != remoteSettings {
            throw MergeError.concurrentSettings
        }
        let settingsDecision: LampSyncThreeWayDecision = remoteRevision > localRevision
            ? .remote : .local
        return Plan(
            settingsDecision: settingsDecision,
            readings: remoteReadings,
            needsPublish: settingsDecision == .local && localSettings != remoteSettings
        )
    }
}
