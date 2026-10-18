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

    /// Bootstrap a client that has no membership baseline. Its caller must
    /// guard any pending upload against the last observed remote token.
    ///
    /// Without a baseline a row only one side holds is ambiguous: it is either
    /// an addition here or a deletion there, and nothing in the two snapshots
    /// says which. This used to refuse the whole merge whenever the two sides
    /// differed at all. That was a dead end rather than a delay — refusing
    /// changed nothing, so the next attempt compared the same rows and refused
    /// again, and the client could never record the baseline that would let it
    /// tell an addition from a deletion. A device could sit there indefinitely,
    /// unable to publish a reading position or to receive one.
    ///
    /// So resolve, biased towards keeping what exists. A row both sides hold is
    /// not ambiguous at all — membership is agreed — so the newer copy wins,
    /// exactly as it would with a baseline, and an exact tie keeps the remote
    /// because this client is the one joining. A row only one side holds is
    /// kept. The cost is that a reading deleted elsewhere, before this client
    /// ever held a baseline, comes back once; from the next merge on there is a
    /// baseline and deletions propagate properly. Reviving one deletion once is
    /// the smaller harm against never syncing at all.
    public static func planWithoutBase<
        Settings: Equatable, Stamp: Comparable, ID: Hashable,
        Reading: Equatable, Revision: Comparable
    >(
        localSettings: Settings,
        localRevision: Stamp,
        localReadings: [ID: Reading],
        remoteSettings: Settings,
        remoteRevision: Stamp,
        remoteReadings: [ID: Reading],
        revision: (Reading) -> Revision
    ) throws -> Plan<ID, Reading> {
        if localRevision == remoteRevision && localSettings != remoteSettings {
            throw MergeError.concurrentSettings
        }
        var mergedReadings = remoteReadings
        for (id, local) in localReadings {
            guard let remote = remoteReadings[id] else {
                mergedReadings[id] = local
                continue
            }
            if revision(local) > revision(remote) {
                mergedReadings[id] = local
            }
        }
        let settingsDecision: LampSyncThreeWayDecision = remoteRevision > localRevision
            ? .remote : .local
        return Plan(
            settingsDecision: settingsDecision,
            readings: mergedReadings,
            needsPublish: mergedReadings != remoteReadings
                || (settingsDecision == .local && localSettings != remoteSettings)
        )
    }
}
