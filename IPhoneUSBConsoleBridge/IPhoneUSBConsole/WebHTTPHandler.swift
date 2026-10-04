import Foundation
import NIOCore
import NIOHTTP1

final class WebHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let pipelineName = "web-http-handler"

    private static let maximumRequestBodyBytes = 16 * 1_024
    private static let maximumStaticFileBytes = 8 * 1_024 * 1_024

    private let runtime: WebConsoleRuntime
    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var requestTooLarge = false

    init(runtime: WebConsoleRuntime) {
        self.runtime = runtime
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard requestHead == nil else {
                context.close(promise: nil)
                return
            }
            requestHead = head
            requestBody.removeAll(keepingCapacity: true)
            requestTooLarge = false
            if let contentLength = head.headers.first(name: "Content-Length").flatMap(Int.init),
               contentLength > Self.maximumRequestBodyBytes {
                requestTooLarge = true
            }
        case .body(var buffer):
            guard !requestTooLarge else { return }
            let readable = buffer.readableBytes
            guard requestBody.count + readable <= Self.maximumRequestBodyBytes,
                  let bytes = buffer.readBytes(length: readable) else {
                requestTooLarge = true
                requestBody.removeAll(keepingCapacity: false)
                return
            }
            requestBody.append(contentsOf: bytes)
        case .end:
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }
            if requestTooLarge {
                respondJSON(
                    context: context,
                    request: head,
                    status: .payloadTooLarge,
                    object: errorObject(code: "payload_too_large", message: "请求正文过大。")
                )
            } else {
                route(context: context, request: head, body: requestBody)
            }
            requestHead = nil
            requestBody.removeAll(keepingCapacity: true)
            requestTooLarge = false
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func route(context: ChannelHandlerContext, request: HTTPRequestHead, body: Data) {
        let path = request.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        if request.method == .POST, path == "/api/bridge/session" {
            handleBridgeSession(context: context, request: request, body: body)
            return
        }

        guard WebRequestSecurity.validHostAndOrigin(
            headers: request.headers,
            requireOrigin: request.method != .GET && request.method != .HEAD
        ) else {
            respondJSON(
                context: context,
                request: request,
                status: .forbidden,
                object: errorObject(code: "forbidden_origin", message: "请求来源不被允许。")
            )
            return
        }

        switch (request.method, path) {
        case (.GET, "/api/session"):
            handleSession(context: context, request: request)
        case (.POST, "/api/login"):
            handleLogin(context: context, request: request, body: body)
        case (.POST, "/api/logout"):
            handleLogout(context: context, request: request)
        case (.GET, "/api/status"):
            handleStatus(context: context, request: request)
        case (.GET, "/ws/video"), (.GET, "/ws/audio"), (.GET, "/ws/audio-pcm"), (.GET, "/ws/control"):
            let authenticated = runtime.auth.validate(
                token: WebRequestSecurity.sessionToken(from: request.headers),
                touch: false
            ) != nil
            respondJSON(
                context: context,
                request: request,
                status: authenticated ? .upgradeRequired : .unauthorized,
                object: errorObject(
                    code: authenticated ? "upgrade_required" : "unauthorized",
                    message: authenticated ? "该端点需要 WebSocket 升级。" : "请先登录。"
                ),
                extraHeaders: authenticated ? [("Upgrade", "websocket")] : []
            )
        case (.GET, _), (.HEAD, _):
            serveStatic(context: context, request: request, path: path)
        default:
            respondJSON(
                context: context,
                request: request,
                status: .methodNotAllowed,
                object: errorObject(code: "method_not_allowed", message: "请求方法不受支持。"),
                extraHeaders: [("Allow", "GET, HEAD, POST")]
            )
        }
    }

    private func handleBridgeSession(
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        body: Data
    ) {
        guard body.isEmpty,
              WebRequestSecurity.validLoopbackBridgeRequest(
                  remoteAddress: context.remoteAddress?.description,
                  headers: request.headers,
                  requireHTTPSOrigin: false
              ),
              let token = WebRequestSecurity.bearerToken(from: request.headers) else {
            respondJSON(
                context: context,
                request: request,
                status: .forbidden,
                object: errorObject(code: "forbidden", message: "本机桥接请求无效。")
            )
            return
        }

        switch runtime.auth.bridgeLogin(bearerToken: token) {
        case .success(let session):
            // A new bridge session invalidates the previous lease. Release any
            // input or microphone state immediately instead of waiting for the
            // replaced WebSocket to notice that its session is no longer valid.
            runtime.controllers.closeAll()
            runtime.inputClient.releaseAllInputs()
            runtime.microphoneCoordinator.stopAll()
            respondJSON(
                context: context,
                request: request,
                status: .ok,
                object: ["authenticated": true, "csrfToken": session.csrfToken],
                extraHeaders: [
                    ("Set-Cookie", sessionCookie(token: session.token)),
                    ("Cache-Control", "no-store")
                ]
            )
        default:
            respondJSON(
                context: context,
                request: request,
                status: .unauthorized,
                object: errorObject(code: "invalid_credentials", message: "本机桥接凭据无效。"),
                extraHeaders: [("Cache-Control", "no-store")]
            )
        }
    }

    private func handleSession(context: ChannelHandlerContext, request: HTTPRequestHead) {
        guard let session = runtime.auth.validate(
            token: WebRequestSecurity.sessionToken(from: request.headers),
            touch: true
        ) else {
            respondJSON(
                context: context,
                request: request,
                status: .unauthorized,
                object: errorObject(code: "unauthorized", message: "请先登录。")
            )
            return
        }
        respondJSON(
            context: context,
            request: request,
            status: .ok,
            object: ["authenticated": true, "csrfToken": session.csrfToken]
        )
    }

    private func handleLogin(
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        body: Data
    ) {
        guard request.headers.first(name: "Content-Type")?
            .lowercased().hasPrefix("application/json") == true,
              let object = WebConsoleJSON.object(body),
              object.count == 1,
              let password = object["password"] as? String,
              password.count >= WebPasswordVerifier.minimumPasswordLength,
              password.utf8.count <= WebPasswordVerifier.maximumPasswordBytes else {
            respondJSON(
                context: context,
                request: request,
                status: .badRequest,
                object: errorObject(code: "invalid_request", message: "密码格式无效。")
            )
            return
        }

        let clientKey = WebRequestSecurity.clientKey(
            remoteAddress: context.remoteAddress?.description,
            headers: request.headers
        )
        let completion = context.eventLoop.makePromise(of: WebAuthStore.LoginResult.self)
        completion.futureResult.whenSuccess { [weak self, weak context] result in
            guard let self, let context, context.channel.isActive else { return }
            self.completeLogin(result: result, context: context, request: request)
        }
        let accepted = runtime.loginGate.submit(
            password: password,
            clientKey: clientKey
        ) { result in
            completion.succeed(result)
        }
        guard accepted else {
            respondJSON(
                context: context,
                request: request,
                status: .tooManyRequests,
                object: errorObject(code: "rate_limited", message: "登录验证队列已满，请稍后再试。"),
                extraHeaders: [("Retry-After", "2")]
            )
            return
        }
    }

    private func completeLogin(
        result: WebAuthStore.LoginResult,
        context: ChannelHandlerContext,
        request: HTTPRequestHead
    ) {
        switch result {
        case .success(let session):
            let previous = runtime.auth.logout(
                token: WebRequestSecurity.sessionToken(from: request.headers)
            )
            if let lease = previous.releasedController {
                runtime.controllers.expire(identifier: lease.identifier)
                runtime.inputClient.releaseAllInputs()
            }
            respondJSON(
                context: context,
                request: request,
                status: .ok,
                object: ["authenticated": true, "csrfToken": session.csrfToken],
                extraHeaders: [("Set-Cookie", sessionCookie(token: session.token))]
            )
        case .invalidCredentials:
            respondJSON(
                context: context,
                request: request,
                status: .unauthorized,
                object: errorObject(code: "invalid_credentials", message: "密码不正确。")
            )
        case .rateLimited(let retryAfterSeconds):
            respondJSON(
                context: context,
                request: request,
                status: .tooManyRequests,
                object: errorObject(code: "rate_limited", message: "尝试次数过多，请稍后再试。"),
                extraHeaders: [("Retry-After", String(retryAfterSeconds))]
            )
        case .capacityReached:
            respondJSON(
                context: context,
                request: request,
                status: .serviceUnavailable,
                object: errorObject(code: "session_capacity", message: "当前查看会话已满，请稍后再试。"),
                extraHeaders: [("Retry-After", "30")]
            )
        }
    }

    private func handleLogout(context: ChannelHandlerContext, request: HTTPRequestHead) {
        let token = WebRequestSecurity.sessionToken(from: request.headers)
        guard let session = runtime.auth.validate(token: token, touch: false),
              let csrf = request.headers.first(name: "X-CSRF-Token"),
              csrf == session.csrfToken else {
            respondJSON(
                context: context,
                request: request,
                status: .forbidden,
                object: errorObject(code: "invalid_csrf", message: "退出凭据无效。")
            )
            return
        }
        let result = runtime.auth.logout(token: token)
        if let lease = result.releasedController {
            runtime.controllers.expire(identifier: lease.identifier)
            runtime.inputClient.releaseAllInputs()
        }
        respond(
            context: context,
            request: request,
            status: .noContent,
            contentType: nil,
            body: Data(),
            extraHeaders: [("Set-Cookie", expiredSessionCookie())]
        )
    }

    private func handleStatus(context: ChannelHandlerContext, request: HTTPRequestHead) {
        guard runtime.auth.validate(
            token: WebRequestSecurity.sessionToken(from: request.headers),
            touch: false
        ) != nil else {
            respondJSON(
                context: context,
                request: request,
                status: .unauthorized,
                object: errorObject(code: "unauthorized", message: "会话已失效。")
            )
            return
        }
        respondJSON(
            context: context,
            request: request,
            status: .ok,
            object: runtime.status.snapshot().statusJSONObject
        )
    }

    private func serveStatic(
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        path: String
    ) {
        let requestedPath = path == "/" ? "index.html" : String(path.dropFirst())
        guard let decodedPath = requestedPath.removingPercentEncoding,
              !decodedPath.isEmpty,
              !decodedPath.contains("\\"),
              !decodedPath.unicodeScalars.contains(where: { $0.value == 0 }),
              !decodedPath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            respondJSON(
                context: context,
                request: request,
                status: .badRequest,
                object: errorObject(code: "invalid_path", message: "资源路径无效。")
            )
            return
        }

        let root = runtime.resourcesRoot.standardizedFileURL
        let fileURL = root.appendingPathComponent(decodedPath).standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue >= 0,
              fileSize.intValue <= Self.maximumStaticFileBytes,
              let contents = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            respondJSON(
                context: context,
                request: request,
                status: .notFound,
                object: errorObject(code: "not_found", message: "资源不存在。")
            )
            return
        }

        let cacheControl = decodedPath == "index.html"
            ? "no-store"
            : "public, max-age=31536000, immutable"
        respond(
            context: context,
            request: request,
            status: .ok,
            contentType: contentType(for: fileURL.pathExtension),
            body: contents,
            extraHeaders: [("Cache-Control", cacheControl)]
        )
    }

    private func respondJSON(
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        status: HTTPResponseStatus,
        object: Any,
        extraHeaders: [(String, String)] = []
    ) {
        let body = WebConsoleJSON.data(object) ?? Data("{}".utf8)
        respond(
            context: context,
            request: request,
            status: status,
            contentType: "application/json; charset=utf-8",
            body: body,
            extraHeaders: extraHeaders
        )
    }

    private func respond(
        context: ChannelHandlerContext,
        request: HTTPRequestHead,
        status: HTTPResponseStatus,
        contentType: String?,
        body: Data,
        extraHeaders: [(String, String)]
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "X-Content-Type-Options", value: "nosniff")
        headers.add(name: "Referrer-Policy", value: "no-referrer")
        headers.add(name: "Permissions-Policy", value: "camera=(), microphone=(self), geolocation=()")
        headers.add(name: "X-Frame-Options", value: "DENY")
        headers.add(name: "Cross-Origin-Opener-Policy", value: "same-origin")
        headers.add(name: "Cross-Origin-Resource-Policy", value: "same-origin")
        headers.add(
            name: "Content-Security-Policy",
            value: "default-src 'self'; script-src 'self'; worker-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        )
        if let contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        for (name, value) in extraHeaders {
            headers.replaceOrAdd(name: name, value: value)
        }

        let responseHead = HTTPResponseHead(version: request.version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        if request.method != .HEAD, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let closePromise = context.eventLoop.makePromise(of: Void.self)
        closePromise.futureResult.whenComplete { [weak channel = context.channel] _ in
            channel?.close(promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: closePromise)
    }

    private func errorObject(code: String, message: String) -> [String: Any] {
        ["code": code, "message": message]
    }

    private func sessionCookie(token: String) -> String {
        "\(WebAuthStore.cookieName)=\(token); Path=/; Max-Age=28800; Secure; HttpOnly; SameSite=Strict"
    }

    private func expiredSessionCookie() -> String {
        "\(WebAuthStore.cookieName)=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"
    }

    private func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
