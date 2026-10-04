import Foundation

enum RemoteStreamProfile: String, CaseIterable, Sendable {
    case low
    case constrained
    case standard
    case software

    var displayName: String {
        switch self {
        case .standard:
            return "标准 · 2 Mbps / 30 fps"
        case .constrained:
            return "受限 · 1.4 Mbps / 30 fps"
        case .low:
            return "弱网 · 1 Mbps / 24 fps"
        case .software:
            return "兼容 · 900 kbps / 20 fps"
        }
    }

    var videoEncoder: String {
        self == .software ? "c2.android.avc.encoder" : "c2.qti.avc.encoder"
    }

    var videoBitrate: String {
        switch self {
        case .standard:
            return "2M"
        case .constrained:
            return "1400K"
        case .low:
            return "1M"
        case .software:
            return "900K"
        }
    }

    var maximumFrameRate: Int {
        switch self {
        case .standard, .constrained:
            return 30
        case .low:
            return 24
        case .software:
            return 20
        }
    }

    var nextLower: RemoteStreamProfile {
        switch self {
        case .standard:
            return .constrained
        case .constrained:
            return .low
        case .low, .software:
            return self
        }
    }

    var nextHigher: RemoteStreamProfile {
        switch self {
        case .low:
            return .constrained
        case .constrained:
            return .standard
        case .standard, .software:
            return self
        }
    }
}

enum RemoteIceMode: String, Sendable {
    case relay
    case direct
}

enum ConnectionCandidatePurpose: Sendable {
    case routeProbe
    case congestionDownshift
    case healthyUpshift
    case encoderFallback
    case latencyRecovery

    var ignoresFailureCooldown: Bool {
        self == .encoderFallback
    }
}

struct ConnectionCandidateRequest: Sendable {
    let iceMode: RemoteIceMode
    let streamProfile: RemoteStreamProfile
    let purpose: ConnectionCandidatePurpose
}

struct ConnectionHealthSample: Sendable {
    let date: Date
    let route: RemoteIceMode?
    let roundTripMilliseconds: Double?
    let jitterMilliseconds: Double?
    let bitrateBitsPerSecond: Double?
    let packetLossRate: Double?
    let framesDecoded: Double
    let framesDropped: Double?
    let keyFramesDecoded: Double?
    let freezeCount: Double?
    let jitterBufferDelayMilliseconds: Double?
    let width: Double?
    let height: Double?
}

struct AdaptiveConnectionPolicy {
    private static let connectionWarmup: TimeInterval = 5
    private static let profileDownDwell: TimeInterval = 22
    private static let profileUpDwell: TimeInterval = 60
    private static let candidateFailureCooldown: TimeInterval = 60
    private static let softwareLease: TimeInterval = 10 * 60
    private static let latencyRecoveryCooldown: TimeInterval = 60
    private static let maximumProfileSwitchesPerHour = 2
    private static let sampleLimit = 30
    // Direct-route probing is DISABLED (maximumRouteProbes = 0). Probing spawns a
    // second "direct" candidate connection every routeProbeRetryInterval and, on
    // success, promotes to it — each promotion tears down and rebuilds the whole
    // session (a visible hard freeze). On mobile/CGNAT networks a direct route is
    // often reachable but unstable, so the session kept flapping relay<->direct
    // every ~20-40s. Staying on the (now Cloudflare) relay for the session's whole
    // life trades a few ms of latency for a rock-steady, freeze-free connection.
    private static let routeProbeRetryInterval: TimeInterval = 45
    private static let maximumRouteProbes = 0
    // Master switch for adaptive reconnects (route-probe / congestion downshift /
    // healthy upshift / latency recovery). DISABLED: the gateway now pins the
    // encode bitrate, so a downshift changes nothing on the wire — it only tears
    // down and rebuilds the whole session (a visible freeze). On a jittery mobile
    // path any transient RTT spike would otherwise trigger a reconnect every ~24s.
    // Staying on the established connection and riding out the dip is far smoother.
    private static let adaptiveReconnectsEnabled = false

    private(set) var preferredProfile: RemoteStreamProfile = AppConfiguration.defaultStreamProfile
    private(set) var activeProfile: RemoteStreamProfile = AppConfiguration.defaultStreamProfile
    private(set) var activeIceMode: RemoteIceMode = .relay
    private(set) var activeConnectedAt: Date?

    private var recentSamples: [ConnectionHealthSample] = []
    private var profileSwitches: [Date] = []
    private var softwareLeaseUntil: Date?
    private var lastPromotionAt: Date?
    private var lastCandidateFailureAt: Date?
    private var lastLatencyRecoveryAt: Date?
    private var lastRouteProbeAt: Date?
    private var routeProbeCount = 0
    private var encoderFallbackAttempted = false

    mutating func resetSession() {
        self = AdaptiveConnectionPolicy()
    }

    mutating func prepareForPrimaryConnection(at now: Date) {
        expireSoftwareLeaseIfNeeded(at: now)
        activeIceMode = .relay
        activeConnectedAt = nil
        recentSamples.removeAll(keepingCapacity: true)
        lastRouteProbeAt = nil
        routeProbeCount = 0
    }

    mutating func registerPrimaryConnection(
        profile: RemoteStreamProfile,
        iceMode: RemoteIceMode,
        at now: Date
    ) {
        activeProfile = profile
        preferredProfile = profile
        activeIceMode = iceMode
        activeConnectedAt = now
        lastPromotionAt = now
        recentSamples.removeAll(keepingCapacity: true)
    }

    mutating func registerPromotion(
        profile: RemoteStreamProfile,
        iceMode: RemoteIceMode,
        at now: Date
    ) {
        let profileChanged = profile != activeProfile
        activeProfile = profile
        preferredProfile = profile
        activeIceMode = iceMode
        activeConnectedAt = now
        lastPromotionAt = now
        recentSamples.removeAll(keepingCapacity: true)

        if profileChanged {
            profileSwitches.append(now)
        }
        if profile == .software {
            softwareLeaseUntil = now.addingTimeInterval(Self.softwareLease)
        }
    }

    mutating func profileForNextConnection(at now: Date) -> RemoteStreamProfile {
        expireSoftwareLeaseIfNeeded(at: now)
        return preferredProfile
    }

    mutating func selectPreferredProfileForReconnect(
        _ profile: RemoteStreamProfile,
        at now: Date
    ) {
        expireSoftwareLeaseIfNeeded(at: now)
        pruneProfileSwitches(at: now)
        if profile != activeProfile {
            profileSwitches.append(now)
        }
        preferredProfile = profile
        lastPromotionAt = now
        recentSamples.removeAll(keepingCapacity: true)

        if profile == .software {
            softwareLeaseUntil = now.addingTimeInterval(Self.softwareLease)
        }
    }

    mutating func markCandidateFailure(
        purpose: ConnectionCandidatePurpose,
        at now: Date
    ) {
        if !purpose.ignoresFailureCooldown {
            lastCandidateFailureAt = now
        }
    }

    mutating func encoderFallbackRequest(
        healthCode: String,
        at now: Date
    ) -> ConnectionCandidateRequest? {
        guard healthCode == "encoder_no_keyframe_after_reset",
              !encoderFallbackAttempted,
              activeProfile != .software
        else {
            return nil
        }
        encoderFallbackAttempted = true
        softwareLeaseUntil = now.addingTimeInterval(Self.softwareLease)
        return ConnectionCandidateRequest(
            iceMode: activeIceMode,
            streamProfile: .software,
            purpose: .encoderFallback
        )
    }

    mutating func consume(
        _ sample: ConnectionHealthSample,
        canStartCandidate: Bool
    ) -> ConnectionCandidateRequest? {
        recentSamples.append(sample)
        if recentSamples.count > Self.sampleLimit {
            recentSamples.removeFirst(recentSamples.count - Self.sampleLimit)
        }

        if !Self.adaptiveReconnectsEnabled {
            return nil
        }

        guard canStartCandidate,
              let connectedAt = activeConnectedAt
        else {
            return nil
        }

        let now = sample.date
        expireSoftwareLeaseIfNeeded(at: now)
        pruneProfileSwitches(at: now)

        let routeProbeDue = lastRouteProbeAt.map {
            now.timeIntervalSince($0) >= Self.routeProbeRetryInterval
        } ?? true
        if routeProbeDue,
           routeProbeCount < Self.maximumRouteProbes,
           activeIceMode == .relay,
           now.timeIntervalSince(connectedAt) >= Self.connectionWarmup,
           sample.framesDecoded > 0,
           candidateCooldownAllows(.routeProbe, at: now) {
            lastRouteProbeAt = now
            routeProbeCount += 1
            return ConnectionCandidateRequest(
                iceMode: .direct,
                streamProfile: activeProfile,
                purpose: .routeProbe
            )
        }

        guard activeProfile != .software,
              now.timeIntervalSince(connectedAt) >= Self.connectionWarmup,
              now.timeIntervalSince(lastPromotionAt ?? connectedAt) >= Self.profileDownDwell,
              profileSwitches.count < Self.maximumProfileSwitchesPerHour
        else {
            return latencyRecoveryRequestIfNeeded(for: sample, at: now)
        }

        // A downshift rebuilds the whole connection (visible as a "connecting"
        // spinner and a multi-second freeze), so it must only fire on sustained
        // trouble — never on a single transient sample.
        let count = recentSamples.count
        var generalCongestionVotes = 0
        if count >= 2 {
            for index in max(1, count - 4)..<count {
                let item = recentSamples[index]
                let prior = recentSamples[index - 1]
                let froze = counterIncreased(
                    current: item.freezeCount,
                    previous: prior.freezeCount
                )
                if (item.packetLossRate ?? 0) >= 0.03
                    || (queueDelay(for: item) ?? 0) >= 100
                    || froze {
                    generalCongestionVotes += 1
                }
            }
        }

        let recentTwo = Array(recentSamples.suffix(2))
        let severeTwice = recentTwo.count == 2 && recentTwo.allSatisfy {
            ($0.packetLossRate ?? 0) >= 0.08 || (queueDelay(for: $0) ?? 0) >= 200
        }
        // The source is producing bits but decoded frames stopped advancing for
        // two consecutive samples.
        let stalledTwice: Bool = {
            guard count >= 3 else { return false }
            let s0 = recentSamples[count - 3]
            let s1 = recentSamples[count - 2]
            let s2 = recentSamples[count - 1]
            let stalled1 = (s1.bitrateBitsPerSecond ?? 0) > 100_000
                && s1.framesDecoded <= s0.framesDecoded
            let stalled2 = (s2.bitrateBitsPerSecond ?? 0) > 100_000
                && s2.framesDecoded <= s1.framesDecoded
            return stalled1 && stalled2
        }()
        let receiveBufferHighTwice = recentTwo.count == 2 && recentTwo.allSatisfy {
            ($0.jitterBufferDelayMilliseconds ?? 0) >= 220
        }

        if stalledTwice
            || severeTwice
            || generalCongestionVotes >= 3
            || receiveBufferHighTwice {
            let lower = activeProfile.nextLower
            if lower != activeProfile,
               candidateCooldownAllows(.congestionDownshift, at: now) {
                return ConnectionCandidateRequest(
                    iceMode: activeIceMode,
                    streamProfile: lower,
                    purpose: .congestionDownshift
                )
            }
        }

        guard now.timeIntervalSince(lastPromotionAt ?? connectedAt) >= Self.profileUpDwell,
              activeProfile != .standard,
              recentSamples.count >= 20,
              candidateCooldownAllows(.healthyUpshift, at: now)
        else {
            return latencyRecoveryRequestIfNeeded(for: sample, at: now)
        }

        let healthyWindow = Array(recentSamples.suffix(20))
        let healthy = healthyWindow.enumerated().allSatisfy { index, item in
            let prior = index > 0 ? healthyWindow[index - 1] : nil
            guard let packetLossRate = item.packetLossRate,
                  let itemQueueDelay = queueDelay(for: item),
                  let jitterBufferDelay = item.jitterBufferDelayMilliseconds
            else {
                return false
            }
            return packetLossRate < 0.01
                && itemQueueDelay < 50
                && jitterBufferDelay < 80
                && !counterIncreased(
                    current: item.freezeCount,
                    previous: prior?.freezeCount
                )
                && (prior == nil || item.framesDecoded > prior!.framesDecoded)
        }
        if healthy {
            let higher = activeProfile.nextHigher
            if higher != activeProfile {
                return ConnectionCandidateRequest(
                    iceMode: activeIceMode,
                    streamProfile: higher,
                    purpose: .healthyUpshift
                )
            }
        }

        return latencyRecoveryRequestIfNeeded(for: sample, at: now)
    }

    func activeRoundTripMedian(maximumSamples: Int = 5) -> Double? {
        median(
            Array(recentSamples.suffix(maximumSamples))
                .compactMap(\.roundTripMilliseconds)
        )
    }

    private mutating func latencyRecoveryRequestIfNeeded(
        for sample: ConnectionHealthSample,
        at now: Date
    ) -> ConnectionCandidateRequest? {
        guard activeProfile == .low,
              recentSamples.count >= 4,
              now.timeIntervalSince(lastLatencyRecoveryAt ?? .distantPast)
                >= Self.latencyRecoveryCooldown,
              candidateCooldownAllows(.latencyRecovery, at: now)
        else {
            return nil
        }

        let recent = recentSamples.suffix(4)
        let highBufferVotes = recent.filter {
            ($0.jitterBufferDelayMilliseconds ?? 0) >= 180
        }.count
        let stalledWhileActive = recent.dropFirst().enumerated().filter { index, item in
            let previous = recent[recent.index(recent.startIndex, offsetBy: index)]
            return (item.bitrateBitsPerSecond ?? 0) > 100_000
                && item.framesDecoded <= previous.framesDecoded
        }.count

        guard highBufferVotes >= 3 || stalledWhileActive >= 2 else {
            return nil
        }
        lastLatencyRecoveryAt = now
        return ConnectionCandidateRequest(
            iceMode: activeIceMode,
            streamProfile: activeProfile,
            purpose: .latencyRecovery
        )
    }

    private func candidateCooldownAllows(
        _ purpose: ConnectionCandidatePurpose,
        at now: Date
    ) -> Bool {
        guard !purpose.ignoresFailureCooldown,
              let lastCandidateFailureAt
        else {
            return true
        }
        return now.timeIntervalSince(lastCandidateFailureAt)
            >= Self.candidateFailureCooldown
    }

    private mutating func expireSoftwareLeaseIfNeeded(at now: Date) {
        guard preferredProfile == .software,
              let softwareLeaseUntil,
              now >= softwareLeaseUntil
        else {
            return
        }
        preferredProfile = AppConfiguration.defaultStreamProfile
        self.softwareLeaseUntil = nil
        encoderFallbackAttempted = false
    }

    private mutating func pruneProfileSwitches(at now: Date) {
        profileSwitches.removeAll {
            now.timeIntervalSince($0) >= 60 * 60
        }
    }

    private func queueDelay(for sample: ConnectionHealthSample) -> Double? {
        guard let current = sample.roundTripMilliseconds else {
            return nil
        }
        let minimum = recentSamples
            .compactMap(\.roundTripMilliseconds)
            .min()
        guard let minimum else { return nil }
        return max(0, current - minimum)
    }

    private func counterIncreased(current: Double?, previous: Double?) -> Bool {
        guard let current, let previous else { return false }
        return current > previous
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
