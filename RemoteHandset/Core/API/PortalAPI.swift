import Foundation

actor PortalAPI {
    private var baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    func currentBaseURL() -> URL {
        baseURL
    }

    func discardLocalSession() {
        clearCookies()
    }

    func checkSession() async throws -> SessionResponse {
        var request = request(path: "/api/auth/session", method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await send(request, as: SessionResponse.self, allowUnauthorized: true)
    }

    func login(password: String) async throws -> SessionResponse {
        let challenge: ChallengeResponse = try await send(
            request(path: "/api/auth/challenge", method: "GET"),
            as: ChallengeResponse.self
        )

        var loginRequest = request(path: "/api/auth/login", method: "POST")
        loginRequest.setValue(origin, forHTTPHeaderField: "Origin")
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.setValue(challenge.csrf, forHTTPHeaderField: "X-CSRF-Token")
        loginRequest.httpBody = try JSONEncoder().encode(["password": password])

        let _: LoginResponse = try await send(loginRequest, as: LoginResponse.self)
        return try await checkSession()
    }

    func logout(csrf: String?) async {
        guard let csrf else {
            clearCookies()
            return
        }

        var request = request(path: "/api/auth/logout", method: "POST")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        _ = try? await session.data(for: request)
        clearCookies()
    }

    func fetchIceConfiguration() async throws -> IceConfigurationResponse {
        try await send(
            request(path: "/api/gateway/ice", method: "GET"),
            as: IceConfigurationResponse.self
        )
    }

    func fetchGatewaySession() async throws -> GatewaySessionResponse {
        try await send(
            request(path: "/api/gateway/session", method: "GET"),
            as: GatewaySessionResponse.self
        )
    }

    /// Use the existing authenticated, short-lived gateway ticket. A separate
    /// socket lets this work even when the device's video connection has failed.
    func deviceConnection(
        deviceID: String,
        preference: String? = nil,
        expectedGeneration: UInt64? = nil,
        expectedInstanceID: String? = nil
    ) async throws -> DeviceConnectionResponse {
        let gateway = try await fetchGatewaySession()
        try Task.checkCancellation()
        let url = try trustedWebSocketURL(from: gateway.websocketUrl)
        let socket = session.webSocketTask(with: websocketRequest(url: url))
        let requestID = UUID().uuidString
        var payload: [String: Any] = [
            "type": preference == nil ? "transport_status" : "transport_switch",
            "request_id": requestID,
            "device_id": deviceID
        ]
        if let preference { payload["preference"] = preference }
        if let expectedGeneration { payload["expected_generation"] = expectedGeneration }
        if let expectedInstanceID { payload["expected_instance_id"] = expectedInstanceID }
        let encoded = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw PortalError.malformedPayload
        }

        socket.resume()
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
        return try await withTaskCancellationHandler {
            try await socket.send(.string(text))
            let message = try await socket.receive()
            try Task.checkCancellation()
            let data: Data
            switch message {
            case let .data(value): data = value
            case let .string(value): data = Data(value.utf8)
            @unknown default: throw PortalError.malformedPayload
            }
            let response = try decoder.decode(DeviceConnectionResponse.self, from: data)
            return try response.validated(requestID: requestID, deviceID: deviceID)
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func trustedWebSocketURL(from value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "wss",
              let gatewayHost = components.host?.lowercased(),
              let portalHost = baseURL.host?.lowercased(),
              gatewayHost == portalHost,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "/screen/ws"
        else {
            throw PortalError.untrustedGatewayAddress
        }

        let gatewayPort = components.port ?? 443
        let portalPort = baseURL.port ?? 443
        guard gatewayPort == portalPort, let url = components.url else {
            throw PortalError.untrustedGatewayAddress
        }
        return url
    }

    func websocketRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(origin, forHTTPHeaderField: "Origin")
        return request
    }

    private var origin: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? baseURL.absoluteString
    }

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable>(
        _ request: URLRequest,
        as type: T.Type,
        allowUnauthorized: Bool = false
    ) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PortalError.invalidResponse
        }

        if (200..<300).contains(http.statusCode) {
            do {
                return try decoder.decode(type, from: data)
            } catch {
                throw PortalError.malformedPayload
            }
        }

        if http.statusCode == 401 {
            if allowUnauthorized, type == SessionResponse.self,
               let value = try? decoder.decode(type, from: data) {
                return value
            }
            throw PortalError.unauthorized
        }

        if http.statusCode == 429 {
            throw PortalError.rateLimited
        }

        let payload = try? decoder.decode(APIErrorPayload.self, from: data)
        throw PortalError.server(
            statusCode: http.statusCode,
            message: payload?.message ?? payload?.error
        )
    }

    private func clearCookies() {
        guard let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) else { return }
        for cookie in cookies {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}
