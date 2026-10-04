import Foundation
import NIOHTTP1
import Security

enum WebSecurityError: Error {
    case randomGenerationFailed
    case passwordDerivationFailed
}

final class BridgeTokenVerifier: @unchecked Sendable {
    private var tokenBytes: [UInt8]

    init(token: String) throws {
        let bytes = Array(token.utf8)
        guard (40...128).contains(bytes.count), bytes.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) ||
                (byte >= 0x41 && byte <= 0x5A) ||
                (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }) else {
            throw WebSecurityError.passwordDerivationFailed
        }
        tokenBytes = bytes
    }

    deinit {
        tokenBytes.withUnsafeMutableBytes { IUSCSecureZeroBuffer($0.baseAddress, $0.count) }
    }

    func verify(token: String) -> Bool {
        var candidate = Array(token.utf8)
        defer {
            candidate.withUnsafeMutableBytes { IUSCSecureZeroBuffer($0.baseAddress, $0.count) }
        }
        guard candidate.count == tokenBytes.count else { return false }
        return candidate.withUnsafeBytes { candidateBuffer in
            tokenBytes.withUnsafeBytes { expectedBuffer in
                IUSCConstantTimeEqual(
                    candidateBuffer.bindMemory(to: UInt8.self).baseAddress,
                    expectedBuffer.bindMemory(to: UInt8.self).baseAddress,
                    candidate.count
                ) == 1
            }
        }
    }
}

struct WebSessionSnapshot: Sendable {
    let token: String
    let csrfToken: String
    let absoluteExpiryMilliseconds: UInt64
}

struct WebControllerLease: Equatable, Sendable {
    let token: String
    let identifier: String
}

final class WebPasswordVerifier: @unchecked Sendable {
    static let minimumPasswordLength = 12
    static let maximumPasswordBytes = 256

    private static let rounds: UInt32 = 600_000
    private static let saltLength = 16
    private static let verifierLength = 32

    private var salt: [UInt8]
    private var verifier: [UInt8]

    init(password: String) throws {
        var passwordBytes = Array(password.utf8)
        defer { Self.clear(&passwordBytes) }
        guard password.count >= Self.minimumPasswordLength,
              passwordBytes.count <= Self.maximumPasswordBytes else {
            throw WebSecurityError.passwordDerivationFailed
        }

        salt = try Self.randomBytes(count: Self.saltLength)
        verifier = [UInt8](repeating: 0, count: Self.verifierLength)
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                verifier.withUnsafeMutableBytes { verifierBuffer in
                    IUSCDerivePBKDF2SHA256(
                        passwordBuffer.bindMemory(to: UInt8.self).baseAddress,
                        passwordBuffer.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        Self.rounds,
                        verifierBuffer.bindMemory(to: UInt8.self).baseAddress,
                        verifierBuffer.count
                    )
                }
            }
        }
        guard status == IUSCUSBMuxSuccess else {
            Self.clear(&verifier)
            throw WebSecurityError.passwordDerivationFailed
        }
    }

    deinit {
        Self.clear(&salt)
        Self.clear(&verifier)
    }

    func verify(password: String) -> Bool {
        var passwordBytes = Array(password.utf8)
        defer { Self.clear(&passwordBytes) }
        guard passwordBytes.count <= Self.maximumPasswordBytes else { return false }

        var candidate = [UInt8](repeating: 0, count: Self.verifierLength)
        defer { Self.clear(&candidate) }
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                candidate.withUnsafeMutableBytes { candidateBuffer in
                    IUSCDerivePBKDF2SHA256(
                        passwordBuffer.bindMemory(to: UInt8.self).baseAddress,
                        passwordBuffer.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        saltBuffer.count,
                        Self.rounds,
                        candidateBuffer.bindMemory(to: UInt8.self).baseAddress,
                        candidateBuffer.count
                    )
                }
            }
        }
        guard status == IUSCUSBMuxSuccess else { return false }
        return candidate.withUnsafeBytes { candidateBuffer in
            verifier.withUnsafeBytes { verifierBuffer in
                IUSCConstantTimeEqual(
                    candidateBuffer.bindMemory(to: UInt8.self).baseAddress,
                    verifierBuffer.bindMemory(to: UInt8.self).baseAddress,
                    candidateBuffer.count
                ) == 1
            }
        }
    }

    static func randomToken(byteCount: Int = 32) throws -> String {
        Data(try randomBytes(count: byteCount))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            clear(&bytes)
            throw WebSecurityError.randomGenerationFailed
        }
        return bytes
    }

    private static func clear(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            IUSCSecureZeroBuffer(buffer.baseAddress, buffer.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }
}

final class WebAuthStore: @unchecked Sendable {
    enum LoginResult {
        case success(WebSessionSnapshot)
        case invalidCredentials
        case rateLimited(retryAfterSeconds: Int)
        case capacityReached
    }

    private struct Session {
        let createdAt: TimeInterval
        let csrfToken: String
        let isBridge: Bool
        var lastSeenAt: TimeInterval
    }

    private struct LoginFailures {
        var timestamps: [TimeInterval] = []
        var blockedUntil: TimeInterval = 0
    }

    static let cookieName = "__Host-IUSC"
    static let idleLifetime: TimeInterval = 30 * 60
    static let absoluteLifetime: TimeInterval = 8 * 60 * 60

    private static let failureWindow: TimeInterval = 10 * 60
    private static let failureLimit = 5
    private static let blockDuration: TimeInterval = 15 * 60
    private static let globalFailureLimit = 20
    private static let globalBlockDuration: TimeInterval = 10 * 60

    private let lock = NSLock()
    private let verifier: WebPasswordVerifier?
    private let bridgeVerifier: BridgeTokenVerifier
    private var sessions: [String: Session] = [:]
    private var currentBridgeSessionToken: String?
    private var failuresByClient: [String: LoginFailures] = [:]
    private var globalFailures = LoginFailures()
    private var controllerLease: WebControllerLease?

    init(verifier: WebPasswordVerifier?, bridgeVerifier: BridgeTokenVerifier) {
        self.verifier = verifier
        self.bridgeVerifier = bridgeVerifier
    }

    func login(password: String, clientKey: String, now: TimeInterval = Date().timeIntervalSince1970) -> LoginResult {
        lock.lock()
        purgeLocked(now: now)
        var failures = failuresByClient[clientKey] ?? LoginFailures()
        let blockedUntil = max(failures.blockedUntil, globalFailures.blockedUntil)
        if blockedUntil > now {
            let retry = max(1, Int(ceil(blockedUntil - now)))
            lock.unlock()
            return .rateLimited(retryAfterSeconds: retry)
        }
        lock.unlock()

        // PBKDF2 deliberately runs outside the store lock so an expensive login
        // attempt cannot block validation of already authenticated sessions.
        let valid = verifier?.verify(password: password) == true

        lock.lock()
        defer { lock.unlock() }
        purgeLocked(now: now)
        failures = failuresByClient[clientKey] ?? LoginFailures()
        failures.timestamps.removeAll { now - $0 > Self.failureWindow }
        globalFailures.timestamps.removeAll { now - $0 > Self.failureWindow }

        guard valid else {
            failures.timestamps.append(now)
            globalFailures.timestamps.append(now)
            if failures.timestamps.count >= Self.failureLimit {
                failures.blockedUntil = now + Self.blockDuration
                failures.timestamps.removeAll(keepingCapacity: false)
            }
            if globalFailures.timestamps.count >= Self.globalFailureLimit {
                globalFailures.blockedUntil = now + Self.globalBlockDuration
                globalFailures.timestamps.removeAll(keepingCapacity: false)
            }
            failuresByClient[clientKey] = failures
            let newBlockedUntil = max(failures.blockedUntil, globalFailures.blockedUntil)
            if newBlockedUntil > now {
                return .rateLimited(retryAfterSeconds: max(1, Int(ceil(newBlockedUntil - now))))
            }
            return .invalidCredentials
        }

        failuresByClient.removeValue(forKey: clientKey)
        // Never evict an authenticated device merely because another device
        // logs in. Capacity is bounded, but an excess login is rejected so all
        // existing viewers keep their sessions and video sockets.
        guard sessions.count < WebCapacity.maximumSessions else {
            return .capacityReached
        }

        guard let token = try? WebPasswordVerifier.randomToken(),
              let csrfToken = try? WebPasswordVerifier.randomToken() else {
            return .invalidCredentials
        }
        sessions[token] = Session(
            createdAt: now,
            csrfToken: csrfToken,
            isBridge: false,
            lastSeenAt: now
        )
        return .success(WebSessionSnapshot(
            token: token,
            csrfToken: csrfToken,
            absoluteExpiryMilliseconds: Self.milliseconds(now + Self.absoluteLifetime)
        ))
    }

    func bridgeLogin(
        bearerToken: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> LoginResult {
        guard bridgeVerifier.verify(token: bearerToken),
              let token = try? WebPasswordVerifier.randomToken(),
              let csrfToken = try? WebPasswordVerifier.randomToken() else {
            return .invalidCredentials
        }

        lock.lock()
        defer { lock.unlock() }
        purgeLocked(now: now)
        if let previous = currentBridgeSessionToken {
            sessions.removeValue(forKey: previous)
            if controllerLease?.token == previous {
                controllerLease = nil
            }
        }
        sessions[token] = Session(
            createdAt: now,
            csrfToken: csrfToken,
            isBridge: true,
            lastSeenAt: now
        )
        currentBridgeSessionToken = token
        return .success(WebSessionSnapshot(
            token: token,
            csrfToken: csrfToken,
            absoluteExpiryMilliseconds: Self.milliseconds(now + Self.absoluteLifetime)
        ))
    }

    func validate(
        token: String?,
        touch: Bool = false,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> WebSessionSnapshot? {
        guard let token, !token.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        purgeLocked(now: now)
        guard var session = sessions[token] else { return nil }
        if touch {
            session.lastSeenAt = now
            sessions[token] = session
        }
        return WebSessionSnapshot(
            token: token,
            csrfToken: session.csrfToken,
            absoluteExpiryMilliseconds: Self.milliseconds(session.createdAt + Self.absoluteLifetime)
        )
    }

    func isBridgeSession(token: String?) -> Bool {
        guard let token else { return false }
        lock.lock()
        defer { lock.unlock() }
        purgeLocked(now: Date().timeIntervalSince1970)
        return sessions[token]?.isBridge == true
    }

    func logout(token: String?) -> (existed: Bool, releasedController: WebControllerLease?) {
        guard let token else { return (false, nil) }
        lock.lock()
        defer { lock.unlock() }
        let existed = sessions.removeValue(forKey: token) != nil
        if currentBridgeSessionToken == token {
            currentBridgeSessionToken = nil
        }
        var releasedController: WebControllerLease?
        if controllerLease?.token == token {
            releasedController = controllerLease
            controllerLease = nil
        }
        return (existed, releasedController)
    }

    func acquireControllerLease(token: String, identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeLocked(now: Date().timeIntervalSince1970)
        guard sessions[token] != nil else { return false }
        guard controllerLease == nil else { return false }
        controllerLease = WebControllerLease(token: token, identifier: identifier)
        return true
    }

    @discardableResult
    func releaseControllerLease(token: String, identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard controllerLease == WebControllerLease(token: token, identifier: identifier) else { return false }
        controllerLease = nil
        return true
    }

    func controllerLeaseIsHeld() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeLocked(now: Date().timeIntervalSince1970)
        return controllerLease != nil
    }

    /// Purges expired sessions and returns the expired controller token, if any.
    func purgeExpired(now: TimeInterval = Date().timeIntervalSince1970) -> WebControllerLease? {
        lock.lock()
        defer { lock.unlock() }
        let previousController = controllerLease
        purgeLocked(now: now)
        return previousController != nil && controllerLease == nil ? previousController : nil
    }

    func removeAllSessions() -> WebControllerLease? {
        lock.lock()
        defer { lock.unlock() }
        let controller = controllerLease
        controllerLease = nil
        sessions.removeAll(keepingCapacity: false)
        currentBridgeSessionToken = nil
        failuresByClient.removeAll(keepingCapacity: false)
        globalFailures = LoginFailures()
        return controller
    }

    private func purgeLocked(now: TimeInterval) {
        let expiredTokens = sessions.compactMap { token, session -> String? in
            let idleExpired = now - session.lastSeenAt >= Self.idleLifetime
            let absolutelyExpired = now - session.createdAt >= Self.absoluteLifetime
            return idleExpired || absolutelyExpired ? token : nil
        }
        for token in expiredTokens {
            sessions.removeValue(forKey: token)
            if currentBridgeSessionToken == token {
                currentBridgeSessionToken = nil
            }
            if controllerLease?.token == token {
                controllerLease = nil
            }
        }
        failuresByClient = failuresByClient.filter { _, failures in
            failures.blockedUntil > now || failures.timestamps.contains { now - $0 <= Self.failureWindow }
        }
        globalFailures.timestamps.removeAll { now - $0 > Self.failureWindow }
        if globalFailures.blockedUntil <= now, globalFailures.timestamps.isEmpty {
            globalFailures = LoginFailures()
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1_000, Double(UInt64.max)).rounded(.down))
    }
}

/// Bounded serial execution for deliberately expensive PBKDF2 logins. The NIO
/// event loops remain non-blocking and a burst cannot fan out into concurrent
/// derivations that consume every CPU core.
final class WebLoginGate: @unchecked Sendable {
    private static let maximumPendingAttempts = 4

    private let auth: WebAuthStore
    private let queue = DispatchQueue(
        label: "local.iphone.usbconsole.web-auth",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var pendingAttempts = 0

    init(auth: WebAuthStore) {
        self.auth = auth
    }

    @discardableResult
    func submit(
        password: String,
        clientKey: String,
        completion: @escaping @Sendable (WebAuthStore.LoginResult) -> Void
    ) -> Bool {
        lock.lock()
        guard pendingAttempts < Self.maximumPendingAttempts else {
            lock.unlock()
            return false
        }
        pendingAttempts += 1
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let result = auth.login(password: password, clientKey: clientKey)
            lock.lock()
            pendingAttempts -= 1
            lock.unlock()
            completion(result)
        }
        return true
    }
}

enum WebRequestSecurity {
    private struct Authority {
        let scheme: String
        let host: String
        let effectivePort: Int
    }

    static func validHostAndOrigin(
        headers: HTTPHeaders,
        requireOrigin: Bool
    ) -> Bool {
        guard let authority = requestAuthority(headers: headers) else { return false }

        let origins = headers[canonicalForm: "origin"]
        if origins.isEmpty {
            return !requireOrigin
        }
        guard origins.count == 1,
              let originURL = URL(string: String(origins[0])),
              let originHost = originURL.host?.lowercased(),
              originURL.user == nil,
              originURL.password == nil,
              originURL.query == nil,
              originURL.fragment == nil,
              originURL.path.isEmpty || originURL.path == "/",
              let originScheme = originURL.scheme?.lowercased(),
              originScheme == authority.scheme,
              originHost == authority.host,
              effectivePort(scheme: originScheme, explicitPort: originURL.port) == authority.effectivePort
        else { return false }

        if originScheme == "https" { return true }
        return originScheme == "http" && isLoopbackHost(originHost)
    }

    static func sessionToken(from headers: HTTPHeaders) -> String? {
        for cookieHeader in headers[canonicalForm: "cookie"] {
            for item in cookieHeader.split(separator: ";", omittingEmptySubsequences: true) {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                if pair[0].trimmingCharacters(in: .whitespaces) == WebAuthStore.cookieName {
                    let token = String(pair[1]).trimmingCharacters(in: .whitespaces)
                    guard token.count >= 32, token.count <= 128,
                          token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
                    else { return nil }
                    return token
                }
            }
        }
        return nil
    }

    static func bearerToken(from headers: HTTPHeaders) -> String? {
        let values = headers[canonicalForm: "authorization"]
        guard values.count == 1 else { return nil }
        let parts = values[0].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = String(parts[1])
        guard (40...128).contains(token.count), token.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }) else { return nil }
        return token
    }

    static func validLoopbackBridgeRequest(
        remoteAddress: String?,
        headers: HTTPHeaders,
        requireHTTPSOrigin: Bool
    ) -> Bool {
        guard isLoopbackRemoteAddress(remoteAddress),
              let hostHeader = headers.first(name: "Host"),
              let host = loopbackHost(fromAuthority: hostHeader),
              effectivePort(scheme: "http", explicitPort: authorityPort(hostHeader)) == 18_765
        else { return false }

        guard requireHTTPSOrigin else { return headers[canonicalForm: "origin"].isEmpty }
        let origins = headers[canonicalForm: "origin"]
        guard origins.count == 1,
              let origin = URL(string: String(origins[0])),
              origin.scheme?.lowercased() == "https",
              origin.user == nil,
              origin.password == nil,
              origin.query == nil,
              origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              origin.host?.lowercased() == host,
              effectivePort(scheme: "https", explicitPort: origin.port) == 18_765
        else { return false }
        return true
    }

    static func clientKey(remoteAddress: String?, headers: HTTPHeaders) -> String {
        // Only a loopback listener can reach this code. Its reverse proxy is
        // therefore allowed to provide the original public client address.
        if let forwarded = headers.first(name: "X-Forwarded-For")?.split(separator: ",").first {
            let candidate = forwarded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, candidate.count <= 64,
               candidate.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                return candidate
            }
        }
        return remoteAddress ?? "loopback"
    }

    private static func requestAuthority(headers: HTTPHeaders) -> Authority? {
        let forwardedProtoValues = headers[canonicalForm: "x-forwarded-proto"]
        guard forwardedProtoValues.count <= 1 else { return nil }
        let scheme: String
        if let rawProto = forwardedProtoValues.first {
            guard !rawProto.contains(",") else { return nil }
            scheme = rawProto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else {
            scheme = "http"
        }
        guard scheme == "http" || scheme == "https" else { return nil }

        let forwardedHostValues = headers[canonicalForm: "x-forwarded-host"]
        let hostValues = headers[canonicalForm: "host"]
        guard forwardedHostValues.count <= 1, hostValues.count == 1 else { return nil }
        let rawHost = String(forwardedHostValues.first ?? hostValues[0])
        guard !rawHost.contains(","),
              rawHost.count <= 255,
              rawHost.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: "\(scheme)://\(rawHost)"),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              let port = effectivePort(scheme: scheme, explicitPort: components.port)
        else { return nil }
        return Authority(scheme: scheme, host: host, effectivePort: port)
    }

    private static func effectivePort(scheme: String, explicitPort: Int?) -> Int? {
        if let explicitPort, (1...65_535).contains(explicitPort) {
            return explicitPort
        }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func isLoopbackRemoteAddress(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value.contains("127.0.0.1") || value.contains("[::1]") ||
            value.contains("/::1:") || value.hasPrefix("::1:")
    }

    private static func loopbackHost(fromAuthority authority: String) -> String? {
        guard let components = URLComponents(string: "http://\(authority)"),
              let host = components.host?.lowercased(), isLoopbackHost(host) else { return nil }
        return host
    }

    private static func authorityPort(_ authority: String) -> Int? {
        URLComponents(string: "http://\(authority)")?.port
    }
}
