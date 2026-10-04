import AppKit
import CoreGraphics
import Darwin
import Foundation

private enum RemoteHandsetAccess {
    static let publicURL = "https://70.39.202.192/"
}

enum HealthState: Int {
    case checking = 0
    case running = 1
    case standby = 2
    case warning = 3
    case failed = 4

    var title: String {
        switch self {
        case .checking: return "检查中"
        case .running: return "正常"
        case .standby: return "正常"
        case .warning: return "受限"
        case .failed: return "不可用"
        }
    }

    var color: NSColor {
        switch self {
        case .checking: return .secondaryLabelColor
        case .running: return NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.58, alpha: 1)
        case .standby: return NSColor(calibratedRed: 0.35, green: 0.70, blue: 1.0, alpha: 1)
        case .warning: return .systemOrange
        case .failed: return .systemRed
        }
    }
}

struct ServiceSnapshot {
    let id: String
    let name: String
    var detail: String
    var state: HealthState
}

struct MonitorSnapshot {
    var services: [ServiceSnapshot]
    let generatedAt: Date
}

struct LaunchdInfo {
    let loaded: Bool
    let state: String
    let pid: Int?
    let runs: Int?
    let lastExitCode: Int?
    let lastExitRaw: String?

    var isRunning: Bool {
        loaded && state == "running"
    }
}

struct HTTPProbeResult {
    let status: Int?
    let okFlag: Bool
    let latencyMs: Int
    let body: Data
}

struct ExternalFunctionalState {
    var peopleBotOK: Bool?
    var archiveBotOK: Bool?
    var financeBotOK: Bool?
    var publicWebReachable: Bool?
    var publicWebCurrent: Bool?
    var prescriptionReachable: Bool?
    var checkedAt: Date

    static let empty = ExternalFunctionalState(
        peopleBotOK: nil,
        archiveBotOK: nil,
        financeBotOK: nil,
        publicWebReachable: nil,
        publicWebCurrent: nil,
        prescriptionReachable: nil,
        checkedAt: .distantPast
    )
}

private final class HTTPProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = HTTPProbeResult(
        status: nil,
        okFlag: false,
        latencyMs: 0,
        body: Data()
    )

    func set(_ result: HTTPProbeResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func get() -> HTTPProbeResult {
        lock.lock()
        let result = stored
        lock.unlock()
        return result
    }
}

private final class ExternalProbeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ExternalFunctionalState

    init(_ initial: ExternalFunctionalState) {
        state = initial
    }

    func update(_ body: (inout ExternalFunctionalState) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }

    func snapshot() -> ExternalFunctionalState {
        lock.lock()
        let value = state
        lock.unlock()
        return value
    }
}

final class ServiceMonitor: @unchecked Sendable {
    private let launchLabels = [
        "homebrew.mxcl.mysql",
        "local.people-sharded-query",
        "local.local-archive-center",
        "local.local-archive-backup",
        "local.local-archive-healthcheck",
        "local.local-archive-logrotate",
        "com.remotehandset.webscreen",
        "com.remotehandset.hk-tunnel",
        "com.remotehandset.watchdog"
    ]

    private var launchCache: [String: LaunchdInfo] = [:]
    private var lastLaunchRefresh = Date.distantPast
    private var externalCache = ExternalFunctionalState.empty
    private var archiveDatabaseCache = (ok: false, tableCount: 0, checkedAt: Date.distantPast)

    func collect() -> MonitorSnapshot {
        let now = Date()
        if now.timeIntervalSince(lastLaunchRefresh) >= 20 || launchCache.isEmpty {
            var fresh: [String: LaunchdInfo] = [:]
            for label in launchLabels {
                fresh[label] = launchdInfo(label)
            }
            launchCache = fresh
            lastLaunchRefresh = now
        }
        if now.timeIntervalSince(externalCache.checkedAt) >= 30 {
            refreshExternalFunctionalState(now: now)
        }
        if now.timeIntervalSince(archiveDatabaseCache.checkedAt) >= 30 {
            let result = archiveDatabaseCheck()
            archiveDatabaseCache = (result.ok, result.tableCount, now)
        }

        let bootGrace = ProcessInfo.processInfo.systemUptime < 240
        let queryInfo = info("local.people-sharded-query")
        let mysqlInfo = info("homebrew.mxcl.mysql")
        let archiveInfo = info("local.local-archive-center")
        let webscreenInfo = info("com.remotehandset.webscreen")
        let tunnelInfo = info("com.remotehandset.hk-tunnel")
        let watchdogInfo = info("com.remotehandset.watchdog")

        let queryRoot = httpProbe("http://127.0.0.1:3000/")
        let querySchema = httpProbe("http://127.0.0.1:3000/api/schema")
        let peopleTableCount = schemaTableCount(querySchema)
        let mysqlOpen = tcpOpen(port: 3306)
        let archiveAPI = httpProbe("http://127.0.0.1:8787/health")
        let archiveAdmin = httpProbe("http://127.0.0.1:5173/")
        let archiveWeb = httpProbe("http://127.0.0.1:5174/")
        let gatewayAuth = httpProbe("http://127.0.0.1:8079/")
        let previewHealth = httpProbe("http://127.0.0.1:8080/healthz")
        let previewPage = httpProbe("http://127.0.0.1:8080/preview")
        let previewConfig = httpProbe("http://127.0.0.1:8080/preview/config")
        let remoteStatus = readKeyValueFile("/Users/zhaogongzi/.remote-handset/watchdog/status")
        let remoteStatusFresh = fileAge("/Users/zhaogongzi/.remote-handset/watchdog/status").map { $0 < 90 } ?? false
        let iphoneStatusPath = "/Users/zhaogongzi/.remote-handset/iphone-console/status"
        let iphoneStatus = readKeyValueFile(iphoneStatusPath)
        let iphoneStatusFresh = fileAge(iphoneStatusPath).map { $0 < 30 } ?? false
        let gatewayAndroidSerials = gatewayManagedAndroidSerials()
        let remoteStatusDeviceCount = Int(remoteStatus["device_count"] ?? "0") ?? 0
        let configuredDeviceCount = max(1, max(remoteStatusDeviceCount, gatewayAndroidSerials.count))
        let managedDeviceSerials = gatewayAndroidSerials.isEmpty
            ? (1...configuredDeviceCount).compactMap { remoteStatus["dev\($0)_serial"] }
            : gatewayAndroidSerials

        var rows: [ServiceSnapshot] = []

        let searchHealthy =
            queryInfo.isRunning &&
            mysqlInfo.isRunning &&
            mysqlOpen &&
            queryRoot.status == 200 &&
            querySchema.status == 200 &&
            peopleTableCount > 0
        rows.append(persistentRow(
            id: "people.business",
            name: "搜索业务",
            info: queryInfo,
            healthy: searchHealthy,
            healthyDetail: "网页可打开 · \(peopleTableCount) 张数据表可查询",
            failureDetail: peopleFailureDetail(
                queryRunning: queryInfo.isRunning,
                mysqlRunning: mysqlInfo.isRunning && mysqlOpen,
                pageStatus: queryRoot.status,
                tableCount: peopleTableCount
            ),
            bootGrace: bootGrace
        ))

        let queryBotRecentError = recentFileContains(
            "/Library/Logs/PeopleSharded/query.err.log",
            text: "[telegram] polling error:",
            within: 120
        )
        if queryInfo.isRunning && externalCache.peopleBotOK == true && !queryBotRecentError {
            rows.append(ServiceSnapshot(
                id: "people.bot",
                name: "消息机器人",
                detail: "Telegram API 可达 · 轮询服务在线",
                state: .running
            ))
        } else if externalCache.peopleBotOK == nil {
            rows.append(ServiceSnapshot(
                id: "people.bot",
                name: "消息机器人",
                detail: "正在验证 Telegram 链路",
                state: .checking
            ))
        } else {
            rows.append(ServiceSnapshot(
                id: "people.bot",
                name: "消息机器人",
                detail: queryBotRecentError ? "Telegram 轮询最近持续报错" : "Telegram API 或机器人进程不可用",
                state: .failed
            ))
        }

        let archiveDataHealthy =
            archiveInfo.isRunning &&
            archiveAPI.status == 200 &&
            archiveAPI.okFlag &&
            archiveDatabaseCache.ok
        rows.append(persistentRow(
            id: "archive.data",
            name: "API 与数据库",
            info: archiveInfo,
            healthy: archiveDataHealthy,
            healthyDetail: "SQLite 完整 · \(archiveDatabaseCache.tableCount) 张表",
            failureDetail: archiveAPI.status == 200 ? "SQLite 完整性检查失败" : "档案 API 无响应",
            bootGrace: bootGrace
        ))

        rows.append(ServiceSnapshot(
            id: "archive.admin",
            name: "管理网页",
            detail: archiveAdmin.status == 200 ? "本机后台页面可访问" : "本机后台页面无响应",
            state: archiveInfo.isRunning && archiveAdmin.status == 200 ? .running : .failed
        ))

        let localEmbeddedWebHealthy = archiveWeb.status == 200
        if !localEmbeddedWebHealthy {
            rows.append(ServiceSnapshot(
                id: "archive.webapp",
                name: "Telegram 内嵌网页",
                detail: "本机 WebApp 无响应",
                state: .failed
            ))
        } else if externalCache.publicWebReachable == false {
            rows.append(ServiceSnapshot(
                id: "archive.webapp",
                name: "Telegram 内嵌网页",
                detail: "公网入口连接超时 · 本机页面正常",
                state: .failed
            ))
        } else if externalCache.publicWebCurrent == false {
            rows.append(ServiceSnapshot(
                id: "archive.webapp",
                name: "Telegram 内嵌网页",
                detail: "公网页面可达，但版本内容异常",
                state: .warning
            ))
        } else if externalCache.publicWebReachable == true {
            rows.append(ServiceSnapshot(
                id: "archive.webapp",
                name: "Telegram 内嵌网页",
                detail: "公网入口与本机页面均可访问",
                state: .running
            ))
        } else {
            rows.append(ServiceSnapshot(
                id: "archive.webapp",
                name: "Telegram 内嵌网页",
                detail: "正在验证公网入口",
                state: .checking
            ))
        }

        let archiveBotProcess = processAlive(
            pidFile: "/Users/zhaogongzi/Documents/Codex/local-archive-center/.runtime/bot.pid"
        )
        let financeBotProcess = processAlive(
            pidFile: "/Users/zhaogongzi/Documents/Codex/local-archive-center/.runtime/finance-bot.pid"
        )
        let botsHealthy =
            archiveBotProcess &&
            financeBotProcess &&
            externalCache.archiveBotOK == true &&
            externalCache.financeBotOK == true
        let botState: HealthState
        let botDetail: String
        if botsHealthy {
            botState = .running
            botDetail = "档案/财务 2 个机器人链路正常"
        } else if externalCache.archiveBotOK == nil || externalCache.financeBotOK == nil {
            botState = .checking
            botDetail = "正在验证 Telegram 链路"
        } else {
            botState = .failed
            var failures: [String] = []
            if !archiveBotProcess || externalCache.archiveBotOK != true { failures.append("档案机器人") }
            if !financeBotProcess || externalCache.financeBotOK != true { failures.append("财务机器人") }
            botDetail = "\(failures.joined(separator: "、"))不可用"
        }
        rows.append(ServiceSnapshot(
            id: "archive.bots",
            name: "机器人消息链路",
            detail: botDetail,
            state: botState
        ))

        if botsHealthy && externalCache.prescriptionReachable == true {
            rows.append(ServiceSnapshot(
                id: "archive.prescription",
                name: "电子处方入口",
                detail: "主机器人与公网处方页面均正常",
                state: .running
            ))
        } else if externalCache.prescriptionReachable == nil {
            rows.append(ServiceSnapshot(
                id: "archive.prescription",
                name: "电子处方入口",
                detail: "正在验证处方页面",
                state: .checking
            ))
        } else {
            rows.append(ServiceSnapshot(
                id: "archive.prescription",
                name: "电子处方入口",
                detail: botsHealthy ? "公网处方页面不可访问" : "主机器人链路不可用",
                state: .failed
            ))
        }

        let relayEnabled = dotenvValue(
            path: "/Users/zhaogongzi/Documents/Codex/local-archive-center/.env",
            keys: ["WEBAPP_RELAY_FORCE_ENABLE"]
        ) == "1"
        let relayRecentlyFailing = recentFileContains(
            "/Users/zhaogongzi/Documents/Codex/local-archive-center/.runtime/logs/bot.log",
            text: "WebApp relay polling failed:",
            within: 15
        )
        if !relayEnabled {
            rows.append(ServiceSnapshot(
                id: "archive.relay",
                name: "兼容表单中继",
                detail: "按本地数据策略关闭",
                state: .standby
            ))
        } else if relayRecentlyFailing {
            rows.append(ServiceSnapshot(
                id: "archive.relay",
                name: "兼容表单中继",
                detail: "公网兼容中继持续连接失败",
                state: .warning
            ))
        } else {
            rows.append(ServiceSnapshot(
                id: "archive.relay",
                name: "兼容表单中继",
                detail: "已启用 · 未发现近期连接错误",
                state: .running
            ))
        }

        rows.append(backupRow(info("local.local-archive-backup"), now: now))

        let previewConfigDevice = jsonString(previewConfig, key: "device_id")
        let previewHealthy =
            webscreenInfo.isRunning &&
            gatewayAuth.status == 401 &&
            previewHealth.status == 204 &&
            previewPage.status == 200 &&
            String(decoding: previewPage.body, as: UTF8.self).contains("远程手机本地预览") &&
            previewConfig.status == 200 &&
            managedDeviceSerials.contains(previewConfigDevice ?? "")
        rows.append(persistentRow(
            id: "remote.preview",
            name: "内嵌预览网页",
            info: webscreenInfo,
            healthy: previewHealthy,
            healthyDetail: "预览页/配置可访问 · 网关鉴权正常",
            failureDetail: gatewayAuth.status == 200 ? "网关鉴权意外关闭" : "预览页面或控制网关不可用",
            bootGrace: bootGrace
        ))

        let hongKongCode = Int(remoteStatus["hong_kong_health_http"] ?? "")
        let proxyCode = Int(remoteStatus["proxy_path_http"] ?? "")
        let watchdogHealthy =
            watchdogInfo.loaded &&
            (watchdogInfo.isRunning || watchdogInfo.lastExitCode == 0)
        let hongKongHealthy =
            tunnelInfo.isRunning &&
            watchdogHealthy &&
            remoteStatusFresh &&
            hongKongCode == 204 &&
            proxyCode == 401
        rows.append(persistentRow(
            id: "remote.hongkong",
            name: "香港访问入口",
            info: tunnelInfo,
            healthy: hongKongHealthy,
            healthyDetail: "HTTPS 204 · 受保护代理 401",
            failureDetail: remoteStatusFresh ? "远端链路检查异常" : "巡检状态已过期",
            bootGrace: bootGrace
        ))

        var phoneStatus = remoteStatus
        for (offset, serial) in managedDeviceSerials.prefix(configuredDeviceCount).enumerated() {
            let index = offset + 1
            let remoteSerial = remoteStatus["dev\(index)_serial"]
            guard remoteSerial != serial else { continue }
            let directStatus = directADBStatus(for: serial)
            phoneStatus["dev\(index)_serial"] = serial
            phoneStatus["dev\(index)_state"] = directStatus.state
            phoneStatus["dev\(index)_boot"] = directStatus.boot
        }
        let phoneRecords: [(id: String, serial: String, state: String, boot: String, configuredName: String?)] =
            (1...configuredDeviceCount).map { index in
                let serial = phoneStatus["dev\(index)_serial"] ?? "手机 \(index)"
                let state = phoneStatus["dev\(index)_state"] ?? (index == 1 ? (phoneStatus["device_state"] ?? "unknown") : "unknown")
                let boot = phoneStatus["dev\(index)_boot"] ?? (index == 1 ? (phoneStatus["boot_completed"] ?? "unknown") : "unknown")
                let configuredName = phoneStatus["dev\(index)_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (id: "remote.phone\(index == 1 ? "" : String(index))", serial: serial, state: state, boot: boot, configuredName: configuredName)
            }
        func phoneName(_ serial: String, configuredName: String? = nil) -> String {
            if let configuredName, !configuredName.isEmpty {
                return configuredName
            }
            switch serial {
            case "ZY22GHBP48": return "微信手机"
            case "ZY22K2SXMK": return "支付宝手机"
            case "ZY22F68DH8": return "白摩托"
            case "31629594940010K": return "备用机1"
            case "ZY22GDWXSZ": return "备用机2"
            case "ZY22HN3ZS4": return "备用机3"
            default: return "被控手机"
            }
        }
        func phoneSnapshot(_ id: String, _ name: String, _ serial: String, _ state: String, _ boot: String) -> ServiceSnapshot {
            if remoteStatusFresh && state == "device" && boot == "1" {
                return ServiceSnapshot(id: id, name: name, detail: "\(serial) · 已连接并完成启动", state: .running)
            } else if remoteStatusFresh && state == "booting" {
                return ServiceSnapshot(id: id, name: name, detail: "\(serial) · 正在启动", state: .warning)
            }
            let reason: String
            if !remoteStatusFresh {
                reason = "巡检状态已过期"
            } else {
                switch state {
                case "missing": reason = "ADB 未发现设备"
                case "offline": reason = "设备离线"
                case "unauthorized": reason = "ADB 未授权"
                case "adb-unavailable": reason = "本机 ADB 不可用"
                case "adb-error", "adb-shell-error": reason = "ADB 通信失败"
                default: reason = "状态异常：\(state)"
                }
            }
            return ServiceSnapshot(id: id, name: name, detail: "\(serial) · \(reason)", state: .failed)
        }
        let phoneRows = phoneRecords.map { record in
            phoneSnapshot(
                record.id,
                phoneName(record.serial, configuredName: record.configuredName),
                record.serial,
                record.state,
                record.boot
            )
        }
        let phoneHealthy = remoteStatusFresh && phoneRecords.allSatisfy {
            $0.state == "device" && $0.boot == "1"
        }

        let iphoneUSBConnected = iphoneStatus["usb_connected"] == "1"
        let iphoneCaptureRunning = iphoneStatus["capture_running"] == "1"
        let iphoneAudioRunning = iphoneStatus["audio_running"] == "1"
        let iphoneDriverRunning = iphoneStatus["driver_running"] == "1"
        let iphoneVideoSocketRunning = iphoneStatus["video_socket_running"] == "1"
        let iphoneAudioSocketRunning = iphoneStatus["audio_socket_running"] == "1"
        let iphoneControlSocketRunning = iphoneStatus["control_socket_running"] == "1"
        let iphoneMicrophoneState = iphoneStatus["microphone_bridge_state"] ?? "idle"
        let iphoneMicrophoneReady = ["direct", "ready", "active"].contains(iphoneMicrophoneState)
        let iphoneFrameFresh = Double(iphoneStatus["video_frame_age_ms"] ?? "")
            .map { $0 >= 0 && $0 < 5_000 } ?? false
        let iphoneHealthy = iphoneStatusFresh &&
            iphoneUSBConnected &&
            iphoneCaptureRunning &&
            iphoneAudioRunning &&
            iphoneDriverRunning &&
            iphoneVideoSocketRunning &&
            iphoneAudioSocketRunning &&
            iphoneControlSocketRunning &&
            iphoneMicrophoneReady &&
            iphoneFrameFresh
        let iphoneDetail: String
        if iphoneHealthy {
            iphoneDetail = "USB 画面、声音、控制和麦克风均就绪"
        } else if !iphoneStatusFresh {
            iphoneDetail = "iPhone Driver 状态未更新"
        } else if !iphoneDriverRunning {
            iphoneDetail = "iPhone Driver 未启动"
        } else if !iphoneUSBConnected {
            iphoneDetail = "USB 未连接或未信任"
        } else if !iphoneCaptureRunning || !iphoneFrameFresh || !iphoneVideoSocketRunning {
            iphoneDetail = "USB 画面采集或传输未就绪"
        } else if !iphoneAudioRunning || !iphoneAudioSocketRunning {
            iphoneDetail = "手机声音采集或传输未就绪"
        } else if !iphoneControlSocketRunning {
            iphoneDetail = "控制通道未就绪"
        } else if !iphoneMicrophoneReady {
            iphoneDetail = "远程麦克风通道未就绪"
        } else {
            iphoneDetail = "iPhone Driver 状态异常"
        }
        let iphoneRow = ServiceSnapshot(
            id: "remote.iphone",
            name: iphoneStatus["display_name"] ?? "苹果11",
            detail: iphoneDetail,
            state: iphoneHealthy ? .running : (bootGrace ? .warning : .failed)
        )

        let fullRemoteHealthy = previewHealthy && hongKongHealthy && phoneHealthy && iphoneHealthy
        var remoteFailure = "远控关键链路不完整"
        if !phoneHealthy {
            remoteFailure = "手机未连接，当前无法远控"
        } else if !iphoneHealthy {
            remoteFailure = "苹果11远控链路未就绪"
        } else if !previewHealthy {
            remoteFailure = "预览或控制网关不可用"
        } else if !hongKongHealthy {
            remoteFailure = "香港访问链路不可用"
        }
        rows.append(ServiceSnapshot(
            id: "remote.complete",
            name: "完整远控",
            detail: fullRemoteHealthy ? "页面、入口、手机均正常" : remoteFailure,
            state: fullRemoteHealthy ? .running : (bootGrace ? .warning : .failed)
        ))
        rows.append(contentsOf: phoneRows)
        rows.append(iphoneRow)

        // Notification forwarder (Android notifications -> Telegram). It is a
        // user LaunchAgent that rewrites seen.txt every poll cycle. Three ADB
        // devices make a normal cycle longer, so keep enough margin to avoid a
        // false alarm while still detecting a genuinely stalled watcher.
        let notifInfo = userLaunchdInfo("com.user.notifforward")
        let notifBeatFresh = fileAge("/Users/zhaogongzi/notif-forward/seen.txt").map { $0 < 75 } ?? false
        let notifPaused = FileManager.default.fileExists(atPath: "/Users/zhaogongzi/notif-forward/paused")
        let notifConfiguredSerials = Set(
            (dotenvValue(
                path: "/Users/zhaogongzi/notif-forward/config.env",
                keys: ["SERIALS"]
            ) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        )
        let notifDevicesConfigured = Set(managedDeviceSerials).isSubset(of: notifConfiguredSerials)
        let notifCachesReady = managedDeviceSerials.allSatisfy {
            FileManager.default.fileExists(atPath: "/Users/zhaogongzi/notif-forward/apps-\($0).txt")
        }
        let notifReady = notifDevicesConfigured && notifCachesReady
        if notifPaused && notifInfo.isRunning && notifReady {
            // Manually paused via bot command — intentional, not a fault.
            rows.append(ServiceSnapshot(
                id: "remote.notif",
                name: "通知转发",
                detail: "已手动暂停 · \(configuredDeviceCount) 台手机配置已就绪",
                state: .standby
            ))
        } else {
            let notifFailureDetail: String
            if !notifDevicesConfigured {
                notifFailureDetail = "通知服务的手机配置不完整"
            } else if !notifCachesReady {
                notifFailureDetail = "通讯 App 缓存尚未就绪"
            } else {
                notifFailureDetail = "进程在运行但未在轮询（可能卡住）"
            }
            rows.append(persistentRow(
                id: "remote.notif",
                name: "通知转发",
                info: notifInfo,
                healthy: notifBeatFresh && notifReady,
                healthyDetail: "转发中 · \(configuredDeviceCount) 台手机监听中",
                failureDetail: notifFailureDetail,
                bootGrace: bootGrace
            ))
        }

        return MonitorSnapshot(services: rows, generatedAt: now)
    }

    private func info(_ label: String) -> LaunchdInfo {
        launchCache[label] ?? LaunchdInfo(
            loaded: false,
            state: "missing",
            pid: nil,
            runs: nil,
            lastExitCode: nil,
            lastExitRaw: nil
        )
    }

    private func refreshExternalFunctionalState(now: Date) {
        let accumulator = ExternalProbeAccumulator(externalCache)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)

        let peopleToken = dotenvValue(
            path: "/Users/zhaogongzi/Services/people-sharded-query/.env",
            keys: ["TELEGRAM_BOT_TOKEN", "BOT_TOKEN"]
        )
        let archiveEnv = "/Users/zhaogongzi/Documents/Codex/local-archive-center/.env"
        let archiveToken = dotenvValue(
            path: archiveEnv,
            keys: ["BOT_TOKEN", "TELEGRAM_BOT_TOKEN"]
        )
        let financeToken = dotenvValue(
            path: archiveEnv,
            keys: ["FINANCE_BOT_TOKEN", "FINANCE_TELEGRAM_BOT_TOKEN"]
        )
        let publicBaseURL = dotenvValue(
            path: archiveEnv,
            keys: ["PUBLIC_WEBAPP_BASE_URL", "WEBAPP_BASE_URL"]
        )

        group.enter()
        queue.async {
            let ok = self.telegramBotHealthy(token: peopleToken)
            accumulator.update { $0.peopleBotOK = ok }
            group.leave()
        }
        group.enter()
        queue.async {
            let ok = self.telegramBotHealthy(token: archiveToken)
            accumulator.update { $0.archiveBotOK = ok }
            group.leave()
        }
        group.enter()
        queue.async {
            let ok = self.telegramBotHealthy(token: financeToken)
            accumulator.update { $0.financeBotOK = ok }
            group.leave()
        }
        group.enter()
        queue.async {
            let status = self.publicWebStatus(baseURL: publicBaseURL)
            accumulator.update {
                $0.publicWebReachable = status.reachable
                $0.publicWebCurrent = status.current
                $0.prescriptionReachable = status.prescription
            }
            group.leave()
        }

        _ = group.wait(timeout: .now() + 5)
        var next = accumulator.snapshot()
        next.checkedAt = now
        externalCache = next
    }

    private func telegramBotHealthy(token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let base = "https://api.telegram.org/bot\(token)"
        let identity = httpProbe("\(base)/getMe", timeout: 2.5)
        guard identity.status == 200, identity.okFlag else { return false }

        let webhook = httpProbe("\(base)/getWebhookInfo", timeout: 2.5)
        guard webhook.status == 200,
              webhook.okFlag,
              let object = jsonDictionary(webhook),
              let result = object["result"] as? [String: Any] else {
            return false
        }
        let webhookURL = result["url"] as? String ?? ""
        return webhookURL.isEmpty
    }

    private func publicWebStatus(baseURL: String?) -> (reachable: Bool, current: Bool, prescription: Bool) {
        guard let baseURL,
              let parsedBase = URL(string: baseURL),
              parsedBase.scheme == "https" else {
            return (false, false, false)
        }

        func url(_ path: String) -> String? {
            let normalizedBase = baseURL.hasSuffix("/") ? baseURL : "\(baseURL)/"
            return URL(string: path, relativeTo: URL(string: normalizedBase))?.absoluteURL.absoluteString
        }

        guard let firstURL = url("tg-new-case.html") else {
            return (false, false, false)
        }
        let first = httpProbe(firstURL, timeout: 2.5)
        guard first.status == 200 else {
            return (false, false, false)
        }

        let firstHTML = String(decoding: first.body, as: UTF8.self)
        var current = pageLooksCurrent(firstHTML)
        for path in [
            "tg-check-record.html",
            "tg-case-detail.html",
            "tg-finance-income.html",
            "tg-form.js"
        ] {
            guard let target = url(path) else {
                current = false
                continue
            }
            let result = httpProbe(target, timeout: 1.5)
            if result.status != 200 || result.body.isEmpty {
                current = false
            }
        }

        var prescription = true
        for path in ["rx-prescription.html", "rx-prescription.js"] {
            guard let target = url(path) else {
                prescription = false
                continue
            }
            let result = httpProbe(target, timeout: 1.5)
            if result.status != 200 || result.body.isEmpty {
                prescription = false
            }
        }
        return (true, current, prescription)
    }

    private func pageLooksCurrent(_ html: String) -> Bool {
        let hasAssets = html.contains("/assets/") || html.contains("assets/")
        let staleMarkers = ["tg-form-config.js", "患者自备", "后台未设置价格"]
        return hasAssets && !staleMarkers.contains(where: html.contains)
    }

    private func archiveDatabaseCheck() -> (ok: Bool, tableCount: Int) {
        let project = "/Users/zhaogongzi/Documents/Codex/local-archive-center"
        let configured = dotenvValue(
            path: "\(project)/.env",
            keys: ["DATABASE_PATH", "DB_PATH"]
        ) ?? "data/archive.sqlite"
        let databasePath = configured.hasPrefix("/")
            ? configured
            : (project as NSString).appendingPathComponent(configured)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            databasePath,
            "PRAGMA quick_check(1); SELECT count(*) FROM sqlite_master WHERE type='table';"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (false, 0)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return (false, 0) }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        return (lines.first == "ok", lines.last.flatMap(Int.init) ?? 0)
    }

    private func schemaTableCount(_ result: HTTPProbeResult) -> Int {
        guard result.status == 200,
              let object = jsonDictionary(result),
              let tables = object["tables"] as? [Any] else {
            return 0
        }
        return tables.count
    }

    private func jsonString(_ result: HTTPProbeResult, key: String) -> String? {
        jsonDictionary(result)?[key] as? String
    }

    private func jsonDictionary(_ result: HTTPProbeResult) -> [String: Any]? {
        guard !result.body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: result.body) as? [String: Any]
    }

    private func peopleFailureDetail(
        queryRunning: Bool,
        mysqlRunning: Bool,
        pageStatus: Int?,
        tableCount: Int
    ) -> String {
        if !queryRunning { return "查询服务未运行" }
        if !mysqlRunning { return "MySQL 数据库不可用" }
        if pageStatus != 200 { return "查询网页不可访问" }
        if tableCount == 0 { return "应用无法读取查询数据表" }
        return "业务链路检查失败"
    }

    private func processAlive(pidFile: String) -> Bool {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return false
        }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func recentFileContains(_ path: String, text: String, within seconds: TimeInterval) -> Bool {
        guard let age = fileAge(path), age <= seconds else { return false }
        return tail(path, maxBytes: 16_384).contains(text)
    }

    private func phoneFailureDetail(state: String, statusFresh: Bool) -> String {
        guard statusFresh else { return "手机巡检状态已过期" }
        switch state {
        case "missing": return "被控手机 · ADB 未发现设备"
        case "offline": return "被控手机 · 设备离线"
        case "unauthorized": return "被控手机 · ADB 未授权"
        case "adb-unavailable": return "本机 ADB 工具不可用"
        case "adb-error", "adb-shell-error": return "手机 ADB 通信失败"
        default: return "手机状态异常：\(state)"
        }
    }

    private func dotenvValue(path: String, keys: [String]) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"") ||
                value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        for key in keys {
            if let value = values[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func persistentRow(
        id: String,
        name: String,
        info: LaunchdInfo,
        healthy: Bool,
        healthyDetail: String,
        failureDetail: String,
        bootGrace: Bool
    ) -> ServiceSnapshot {
        if info.isRunning && healthy {
            return ServiceSnapshot(id: id, name: name, detail: healthyDetail, state: .running)
        }

        if bootGrace {
            return ServiceSnapshot(id: id, name: name, detail: "系统服务正在启动", state: .warning)
        }

        if !info.loaded {
            return ServiceSnapshot(id: id, name: name, detail: "launchd 服务未加载", state: .failed)
        }

        if !info.isRunning {
            if let code = info.lastExitCode {
                return ServiceSnapshot(id: id, name: name, detail: "进程已停止 · 退出码 \(code)", state: .failed)
            }
            return ServiceSnapshot(id: id, name: name, detail: "进程未运行", state: .failed)
        }

        return ServiceSnapshot(id: id, name: name, detail: failureDetail, state: .failed)
    }

    private func scheduledRow(
        id: String,
        name: String,
        schedule: String,
        info: LaunchdInfo
    ) -> ServiceSnapshot {
        if !info.loaded {
            return ServiceSnapshot(id: id, name: name, detail: "定时任务未加载", state: .warning)
        }
        if info.isRunning {
            return ServiceSnapshot(id: id, name: name, detail: "\(schedule) · 正在执行", state: .running)
        }
        if let code = info.lastExitCode, code != 0 {
            return ServiceSnapshot(id: id, name: name, detail: "\(schedule) · 上次退出码 \(code)", state: .warning)
        }
        let suffix = info.lastExitCode == nil ? "尚未执行" : "上次成功"
        return ServiceSnapshot(id: id, name: name, detail: "\(schedule) · \(suffix)", state: .standby)
    }

    private func backupRow(_ info: LaunchdInfo, now: Date) -> ServiceSnapshot {
        var base = scheduledRow(
            id: "archive.backup",
            name: "每日备份",
            schedule: "每天 02:00",
            info: info
        )
        guard base.state == .standby else { return base }

        let directory = "/Users/zhaogongzi/Documents/Codex/backups/archive-daily"
        let latest = latestFile(in: directory, prefix: "archive-", suffix: ".sqlite")
        let logTail = tail("/Users/zhaogongzi/Documents/Codex/local-archive-center/.runtime/logs/backup.log")
        let logHealthy = logTail.contains("integrity=ok") &&
            logTail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("done")

        guard let latest else {
            base.state = .warning
            base.detail = "未找到有效备份"
            return base
        }

        let age = now.timeIntervalSince(latest.date)
        guard latest.size > 0, age < 36 * 3600, logHealthy else {
            base.state = .warning
            base.detail = age >= 36 * 3600 ? "最近备份已超过 36 小时" : "最近备份完整性待确认"
            return base
        }

        base.detail = "\(relativeDay(latest.date)) \(clock(latest.date)) · 完整性正常"
        return base
    }

    private func logRotateRow(_ info: LaunchdInfo, now: Date) -> ServiceSnapshot {
        var base = scheduledRow(
            id: "archive.logrotate",
            name: "日志轮转",
            schedule: "每天 02:30",
            info: info
        )
        guard base.state == .standby else { return base }

        let path = "/Users/zhaogongzi/Documents/Codex/local-archive-center/.runtime/logs/rotate.log"
        let age = fileAge(path)
        let logTail = tail(path)
        let finished = logTail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("rotate done")
        if let age, age < 36 * 3600, finished {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attributes[.modificationDate] as? Date {
                base.detail = "\(relativeDay(date)) \(clock(date)) · 上次成功"
            }
        } else {
            base.state = .warning
            base.detail = "最近轮转结果待确认"
        }
        return base
    }

    private func watchdogRow(
        _ info: LaunchdInfo,
        status: [String: String],
        statusFresh: Bool
    ) -> ServiceSnapshot {
        var base = scheduledRow(
            id: "remote.watchdog",
            name: "自动看护",
            schedule: "每 30 秒",
            info: info
        )
        guard base.state != .warning else { return base }

        guard statusFresh else {
            base.state = .warning
            base.detail = "每 30 秒 · 巡检状态已过期"
            return base
        }

        let device = status["device_state"] ?? "unknown"
        let boot = status["boot_completed"] ?? "unknown"
        switch device {
        case "device" where boot == "1":
            base.detail = "每 30 秒 · 手机在线"
        case "booting":
            base.state = .warning
            base.detail = "每 30 秒 · 手机启动中"
        case "missing", "offline":
            base.state = .warning
            base.detail = "每 30 秒 · 手机未连接"
        case "unauthorized":
            base.state = .warning
            base.detail = "每 30 秒 · 手机未授权"
        default:
            base.state = .warning
            base.detail = "每 30 秒 · 手机状态 \(device)"
        }
        return base
    }

    private func archiveFailureDetail(api: Int?, admin: Int?, web: Int?) -> String {
        var failed: [String] = []
        if api != 200 { failed.append("API") }
        if admin != 200 { failed.append("管理端") }
        if web != 200 { failed.append("查询端") }
        return failed.isEmpty ? "接口检查异常" : "\(failed.joined(separator: "、"))无响应"
    }

    private func portPIDDetail(_ ports: String, _ pid: Int?) -> String {
        guard let pid else { return ports }
        return "\(ports) · PID \(pid)"
    }

    private func launchdInfo(_ label: String) -> LaunchdInfo {
        launchdInfo(domain: "system", label: label)
    }

    // User LaunchAgents live in the per-user GUI domain, not the system domain.
    private func userLaunchdInfo(_ label: String) -> LaunchdInfo {
        launchdInfo(domain: "gui/\(getuid())", label: label)
    }

    private func launchdInfo(domain: String, label: String) -> LaunchdInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(domain)/\(label)"]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return LaunchdInfo(loaded: false, state: "missing", pid: nil, runs: nil, lastExitCode: nil, lastExitRaw: nil)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return LaunchdInfo(loaded: false, state: "missing", pid: nil, runs: nil, lastExitCode: nil, lastExitRaw: nil)
        }

        let text = String(decoding: data, as: UTF8.self)
        let state = capture(#"(?m)^\s*state = (.+)$"#, in: text) ?? "unknown"
        let pid = capture(#"(?m)^\s*pid = ([0-9]+)$"#, in: text).flatMap(Int.init)
        let runs = capture(#"(?m)^\s*runs = ([0-9]+)$"#, in: text).flatMap(Int.init)
        let lastExitRaw = capture(#"(?m)^\s*last exit code = (.+)$"#, in: text)
        let lastExitCode = lastExitRaw.flatMap { raw -> Int? in
            Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return LaunchdInfo(
            loaded: true,
            state: state.trimmingCharacters(in: .whitespacesAndNewlines),
            pid: pid,
            runs: runs,
            lastExitCode: lastExitCode,
            lastExitRaw: lastExitRaw
        )
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private func httpProbe(_ urlString: String, timeout: TimeInterval = 1.5) -> HTTPProbeResult {
        guard let url = URL(string: urlString) else {
            return HTTPProbeResult(status: nil, okFlag: false, latencyMs: 0, body: Data())
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout

        let box = HTTPProbeBox()
        let semaphore = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            let latency = Int(elapsed / 1_000_000)
            let status = (response as? HTTPURLResponse)?.statusCode
            let body = data ?? Data()
            var okFlag = false
            if !body.isEmpty,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let ok = object["ok"] as? Bool {
                okFlag = ok
            }
            box.set(HTTPProbeResult(
                status: status,
                okFlag: okFlag,
                latencyMs: latency,
                body: body
            ))
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.25) == .timedOut {
            task.cancel()
            return HTTPProbeResult(
                status: nil,
                okFlag: false,
                latencyMs: Int(timeout * 1000),
                body: Data()
            )
        }
        return box.get()
    }

    private func tcpOpen(port: UInt16, timeoutMilliseconds: Int32 = 1_000) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard "127.0.0.1".withCString({
            Darwin.inet_pton(AF_INET, $0, &address.sin_addr)
        }) == 1 else {
            return false
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        let pollResult = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard pollResult > 0 else { return false }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 else {
            return false
        }
        return socketError == 0
    }

    private func readKeyValueFile(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            result[key] = value
        }
        return result
    }

    private func gatewayManagedAndroidSerials() -> [String] {
        let path = "/Users/zhaogongzi/.remote-handset/run-webscreen-secure.sh"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        guard let line = text.split(whereSeparator: \.isNewline).first(where: {
            $0.hasPrefix("export WEBSCREEN_DEVICE_ID=")
        }) else {
            return []
        }
        let valueStart = line.index(line.startIndex, offsetBy: "export WEBSCREEN_DEVICE_ID=".count)
        let rawValue = String(line[valueStart...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "iphone11-usb" }
    }

    private func directADBStatus(for serial: String) -> (state: String, boot: String) {
        let stateResult = runCommand(
            executable: "/opt/homebrew/bin/adb",
            arguments: ["-s", serial, "get-state"]
        )
        let state = stateResult.status == 0
            ? stateResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : "missing"
        guard state == "device" else {
            return (state.isEmpty ? "missing" : state, "unknown")
        }

        let bootResult = runCommand(
            executable: "/opt/homebrew/bin/adb",
            arguments: ["-s", serial, "shell", "getprop", "sys.boot_completed"]
        )
        let boot = bootResult.status == 0
            ? bootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : "unknown"
        return (state, boot.isEmpty ? "unknown" : boot)
    }

    private func runCommand(executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (127, "")
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func fileAge(_ path: String) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return Date().timeIntervalSince(modified)
    }

    private func latestFile(in directory: String, prefix: String, suffix: String) -> (date: Date, size: Int64)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        var latest: (Date, Int64)?
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let date = attributes[.modificationDate] as? Date else {
                continue
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if latest == nil || date > latest!.0 {
                latest = (date, size)
            }
        }
        return latest
    }

    private func tail(_ path: String, maxBytes: UInt64 = 32_768) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

final class StatusBadgeView: NSView {
    private let label = NSTextField(labelWithString: "检查中")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        apply(.checking)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: HealthState) {
        label.stringValue = state.title
        label.textColor = state.color
        layer?.backgroundColor = state.color.withAlphaComponent(0.14).cgColor
        layer?.borderColor = state.color.withAlphaComponent(0.24).cgColor
        layer?.borderWidth = 0.5
    }
}

final class StatusDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        apply(.checking)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: HealthState) {
        layer?.backgroundColor = state.color.cgColor
        layer?.shadowColor = state.color.cgColor
        layer?.shadowOpacity = state == .checking ? 0 : 0.45
        layer?.shadowRadius = 3
        layer?.shadowOffset = .zero
    }
}

final class ServiceRowView: NSView {
    let id: String
    private let nameLabel: NSTextField
    private let detailLabel = NSTextField(labelWithString: "正在检查…")
    private let dot = StatusDotView(frame: .zero)
    private let badge = StatusBadgeView(frame: .zero)

    init(id: String, name: String, showSeparator: Bool) {
        self.id = id
        self.nameLabel = NSTextField(labelWithString: name)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.8, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        dot.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(badge)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 62),
            badge.heightAnchor.constraint(equalToConstant: 22)
        ])

        if showSeparator {
            let separator = NSView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
            addSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: bottomAnchor),
                separator.heightAnchor.constraint(equalToConstant: 0.5)
            ])
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ snapshot: ServiceSnapshot) {
        nameLabel.stringValue = snapshot.name
        detailLabel.stringValue = snapshot.detail
        dot.apply(snapshot.state)
        badge.apply(snapshot.state)
        setAccessibilityLabel("\(snapshot.name)，\(snapshot.state.title)，\(snapshot.detail)")
    }
}

final class CardView: NSView {
    let id: String
    private let serviceIDs: [String]
    private let criticalID: String
    private let groupStatusLabel = NSTextField(labelWithString: "检查中")
    private let groupStatusDot = StatusDotView(frame: .zero)

    init(id: String, title: String, symbolName: String, criticalID: String, rows: [(String, String)]) {
        self.id = id
        self.serviceIDs = rows.map(\.0)
        self.criticalID = criticalID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        updateSurface()

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 7, right: 12)
        addSubview(stack)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 23).isActive = true

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        image.contentTintColor = NSColor(calibratedRed: 0.43, green: 0.78, blue: 1, alpha: 1)

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .secondaryLabelColor

        groupStatusDot.translatesAutoresizingMaskIntoConstraints = false
        groupStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        groupStatusLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        groupStatusLabel.textColor = .tertiaryLabelColor
        groupStatusLabel.alignment = .right

        header.addSubview(image)
        header.addSubview(label)
        header.addSubview(groupStatusDot)
        header.addSubview(groupStatusLabel)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 1),
            image.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -1),
            image.widthAnchor.constraint(equalToConstant: 14),
            image.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: groupStatusDot.leadingAnchor, constant: -8),
            groupStatusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            groupStatusLabel.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            groupStatusDot.trailingAnchor.constraint(equalTo: groupStatusLabel.leadingAnchor, constant: -6),
            groupStatusDot.centerYAnchor.constraint(equalTo: groupStatusLabel.centerYAnchor),
            groupStatusDot.widthAnchor.constraint(equalToConstant: 6),
            groupStatusDot.heightAnchor.constraint(equalToConstant: 6)
        ])
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        for (index, row) in rows.enumerated() {
            let rowView = ServiceRowView(
                id: row.0,
                name: row.1,
                showSeparator: index < rows.count - 1
            )
            stack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: CGFloat(38 + rows.count * 36))
        ])
    }

    func apply(_ states: [String: HealthState]) {
        let relevant = serviceIDs.compactMap { states[$0] }
        let critical = states[criticalID] ?? .checking
        let hasProblem = relevant.contains(.failed) || relevant.contains(.warning)
        let state: HealthState
        let title: String
        if critical == .failed {
            state = .failed
            title = "不可用"
        } else if critical == .checking {
            state = .checking
            title = "检查中"
        } else if hasProblem {
            state = .warning
            title = "部分不可用"
        } else if relevant.allSatisfy({ $0 == .running || $0 == .standby }) {
            state = .running
            title = "可用"
        } else {
            state = .checking
            title = "检查中"
        }
        groupStatusLabel.stringValue = title
        groupStatusLabel.textColor = state.color
        groupStatusDot.apply(state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.30).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.30).cgColor
        layer?.borderWidth = 0.5
    }
}

final class HeaderView: NSView {
    let refreshButton = NSButton()
    let menuButton = NSButton()
    private let updatedLabel = NSTextField(labelWithString: "正在读取服务状态…")
    private let overallLabel = NSTextField(labelWithString: "检查中")
    private let overallDot = StatusDotView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 58).isActive = true

        let title = NSTextField(labelWithString: "业务可用性")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .labelColor

        let liveLabel = NSTextField(labelWithString: "LIVE")
        liveLabel.translatesAutoresizingMaskIntoConstraints = false
        liveLabel.font = .monospacedSystemFont(ofSize: 8.5, weight: .bold)
        liveLabel.textColor = NSColor(calibratedRed: 0.43, green: 0.78, blue: 1, alpha: 1)

        updatedLabel.translatesAutoresizingMaskIntoConstraints = false
        updatedLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        updatedLabel.textColor = .secondaryLabelColor

        overallDot.translatesAutoresizingMaskIntoConstraints = false
        overallLabel.translatesAutoresizingMaskIntoConstraints = false
        overallLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        overallLabel.textColor = .secondaryLabelColor
        overallLabel.alignment = .right

        configureIconButton(refreshButton, symbol: "arrow.clockwise", toolTip: "立即刷新")
        configureIconButton(menuButton, symbol: "ellipsis", toolTip: "更多")

        addSubview(title)
        addSubview(liveLabel)
        addSubview(updatedLabel)
        addSubview(overallDot)
        addSubview(overallLabel)
        addSubview(refreshButton)
        addSubview(menuButton)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            liveLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            liveLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -1),

            updatedLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            updatedLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 26),
            menuButton.heightAnchor.constraint(equalToConstant: 26),

            refreshButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -2),
            refreshButton.topAnchor.constraint(equalTo: topAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 26),
            refreshButton.heightAnchor.constraint(equalToConstant: 26),

            overallLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            overallLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            overallDot.trailingAnchor.constraint(equalTo: overallLabel.leadingAnchor, constant: -7),
            overallDot.centerYAnchor.constraint(equalTo: overallLabel.centerYAnchor),
            overallDot.widthAnchor.constraint(equalToConstant: 8),
            overallDot.heightAnchor.constraint(equalToConstant: 8),
            overallDot.leadingAnchor.constraint(greaterThanOrEqualTo: updatedLabel.trailingAnchor, constant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRefreshing(_ refreshing: Bool) {
        refreshButton.isEnabled = !refreshing
        if refreshing {
            updatedLabel.stringValue = "正在刷新…"
        }
    }

    func apply(_ snapshot: MonitorSnapshot) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        updatedLabel.stringValue = "更新于 \(formatter.string(from: snapshot.generatedAt))"

        let states = Dictionary(uniqueKeysWithValues: snapshot.services.map { ($0.id, $0.state) })
        func groupState(prefix: String, criticalID: String) -> HealthState {
            let critical = states[criticalID] ?? .checking
            if critical == .failed { return .failed }
            if critical == .checking { return .checking }
            let relevant = states.filter { $0.key.hasPrefix(prefix) }.map(\.value)
            if relevant.contains(.failed) || relevant.contains(.warning) { return .warning }
            if relevant.contains(.checking) { return .checking }
            return .running
        }
        let groups = [
            groupState(prefix: "people.", criticalID: "people.business"),
            groupState(prefix: "archive.", criticalID: "archive.data"),
            groupState(prefix: "remote.", criticalID: "remote.complete")
        ]
        let affected = groups.filter { $0 == .failed || $0 == .warning }.count
        let state: HealthState
        if groups.contains(.failed) {
            overallLabel.stringValue = "\(affected) 个系统受影响"
            state = .failed
        } else if groups.contains(.warning) {
            overallLabel.stringValue = "\(affected) 个系统受影响"
            state = .warning
        } else if groups.contains(.checking) {
            overallLabel.stringValue = "正在检查"
            state = .checking
        } else {
            overallLabel.stringValue = "全部系统可用"
            state = .running
        }
        overallLabel.textColor = state.color
        overallDot.apply(state)
    }

    private func configureIconButton(_ button: NSButton, symbol: String, toolTip: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
    }
}

final class WidgetSurfaceView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    func updateSurface() {
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.6
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.40).cgColor
        // NSVisualEffectView itself follows the system's Reduce Transparency setting.
        // Keep only a light tint here so changing that setting takes effect immediately.
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.08).cgColor
    }
}

final class RemoteAccessFooterView: NSView {
    private let addressButton = NSButton()
    private var feedbackResetWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let label = NSTextField(labelWithString: "远控地址")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 9.5, weight: .regular)
        label.textColor = .tertiaryLabelColor

        addressButton.translatesAutoresizingMaskIntoConstraints = false
        addressButton.isBordered = false
        addressButton.imagePosition = .imageTrailing
        addressButton.image = copyImage()
        addressButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        addressButton.contentTintColor = .linkColor
        addressButton.attributedTitle = addressTitle()
        addressButton.target = self
        addressButton.action = #selector(copyAddress(_:))
        addressButton.toolTip = "复制远控访问地址"
        addressButton.setAccessibilityLabel("复制远控访问地址 \(RemoteHandsetAccess.publicURL)")

        let row = NSStackView(views: [label, addressButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        addSubview(row)

        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            addressButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func copyAddress(_ sender: Any?) {
        feedbackResetWorkItem?.cancel()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(RemoteHandsetAccess.publicURL, forType: .string)

        addressButton.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "已复制"
        )
        addressButton.contentTintColor = .systemGreen
        addressButton.toolTip = "已复制 \(RemoteHandsetAccess.publicURL)"

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.addressButton.image = self.copyImage()
            self.addressButton.contentTintColor = .linkColor
            self.addressButton.toolTip = "复制远控访问地址"
        }
        feedbackResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func addressTitle() -> NSAttributedString {
        NSAttributedString(
            string: RemoteHandsetAccess.publicURL,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10.2, weight: .medium),
                .foregroundColor: NSColor.linkColor
            ]
        )
    }

    private func copyImage() -> NSImage? {
        NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "复制"
        )
    }
}

final class WidgetView: NSView {
    let header = HeaderView(frame: .zero)
    private var rowViews: [String: ServiceRowView] = [:]
    private var groupViews: [String: CardView] = [:]

    init(actionTarget: AppDelegate) {
        super.init(frame: .zero)

        let effect = WidgetSurfaceView()
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.updateSurface()
        addSubview(effect)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 9
        effect.addSubview(stack)

        header.refreshButton.target = actionTarget
        header.refreshButton.action = #selector(AppDelegate.refreshClicked(_:))
        header.menuButton.target = actionTarget
        header.menuButton.action = #selector(AppDelegate.menuClicked(_:))
        stack.addArrangedSubview(header)

        let groups: [(String, String, String, String, [(String, String)])] = [
            (
                "people",
                "人员查询",
                "person.text.rectangle",
                "people.business",
                [
                    ("people.business", "搜索业务"),
                    ("people.bot", "消息机器人")
                ]
            ),
            (
                "archive",
                "本地档案",
                "archivebox",
                "archive.data",
                [
                    ("archive.data", "API 与数据库"),
                    ("archive.admin", "管理网页"),
                    ("archive.webapp", "Telegram 内嵌网页"),
                    ("archive.bots", "机器人消息链路"),
                    ("archive.prescription", "电子处方入口"),
                    ("archive.relay", "兼容表单中继"),
                    ("archive.backup", "每日备份")
                ]
            ),
            (
                "remote",
                "远程手机",
                "iphone.and.arrow.forward",
                "remote.complete",
                [
                    ("remote.complete", "完整远控"),
                    ("remote.preview", "内嵌预览网页"),
                    ("remote.hongkong", "香港访问入口"),
                    ("remote.phone", "微信手机"),
                    ("remote.phone2", "支付宝手机"),
                    ("remote.phone3", "白摩托"),
                    ("remote.phone4", "备用机1"),
                    ("remote.phone5", "备用机2"),
                    ("remote.phone6", "备用机3"),
                    ("remote.iphone", "苹果11"),
                    ("remote.notif", "通知转发")
                ]
            )
        ]

        for group in groups {
            let card = CardView(
                id: group.0,
                title: group.1,
                symbolName: group.2,
                criticalID: group.3,
                rows: group.4
            )
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            groupViews[card.id] = card
            collectRows(in: card)
        }

        let footer = RemoteAccessFooterView(frame: .zero)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),

            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ snapshot: MonitorSnapshot) {
        let states = Dictionary(
            uniqueKeysWithValues: snapshot.services.map { ($0.id, $0.state) }
        )
        for service in snapshot.services {
            rowViews[service.id]?.apply(service)
        }
        for group in groupViews.values {
            group.apply(states)
        }
        header.apply(snapshot)
    }

    private func collectRows(in view: NSView) {
        if let row = view as? ServiceRowView {
            rowViews[row.id] = row
        }
        for subview in view.subviews {
            collectRows(in: subview)
        }
    }
}

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let monitor = ServiceMonitor()
    private let probeQueue = DispatchQueue(label: "local.service-status-widget.probes", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var panel: DesktopPanel?
    private var widgetView: WidgetView?
    private var refreshing = false
    private var failureStreaks: [String: Int] = [:]
    private var lastStates: [String: HealthState] = [:]
    private let frameName = "LocalServiceStatusPanelFrame"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let size = NSSize(width: 412, height: 868)
        let panel = DesktopPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true

        let widgetView = WidgetView(actionTarget: self)
        widgetView.frame = NSRect(origin: .zero, size: size)
        widgetView.autoresizingMask = [.width, .height]
        widgetView.menu = makeMenu()
        panel.contentView = widgetView

        let restored = panel.setFrameUsingName(frameName)
        if !restored {
            placeDefault(panel)
        } else {
            var restoredFrame = panel.frame
            restoredFrame.size = size
            panel.setFrame(restoredFrame, display: false)
            constrainToVisibleScreen(panel)
        }
        _ = panel.setFrameAutosaveName(frameName)
        panel.saveFrame(usingName: frameName)

        self.panel = panel
        self.widgetView = widgetView
        panel.orderFrontRegardless()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        startTimer()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc func refreshClicked(_ sender: Any?) {
        refresh()
    }

    @objc func menuClicked(_ sender: NSButton) {
        let menu = makeMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY),
            in: sender
        )
    }

    @objc func resetPositionClicked(_ sender: Any?) {
        if let panel {
            placeDefault(panel)
            panel.saveFrame(usingName: frameName)
        }
    }

    @objc func quitClicked(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        refresh()
    }

    @objc private func screenConfigurationChanged(_ notification: Notification) {
        if let panel {
            constrainToVisibleScreen(panel)
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(350))
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        self.timer = timer
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        widgetView?.header.setRefreshing(true)
        probeQueue.async { [weak self] in
            guard let self else { return }
            let raw = self.monitor.collect()
            DispatchQueue.main.async {
                let stable = self.stabilized(raw)
                self.widgetView?.apply(stable)
                self.widgetView?.header.setRefreshing(false)
                self.refreshing = false
            }
        }
    }

    private func stabilized(_ snapshot: MonitorSnapshot) -> MonitorSnapshot {
        var services = snapshot.services
        for index in services.indices {
            let id = services[index].id
            if services[index].state == .failed {
                let streak = (failureStreaks[id] ?? 0) + 1
                failureStreaks[id] = streak
                if streak == 1, lastStates[id] != nil {
                    services[index].state = .warning
                    services[index].detail += " · 正在重试"
                }
            } else {
                failureStreaks[id] = 0
            }
            lastStates[id] = services[index].state
        }
        return MonitorSnapshot(services: services, generatedAt: snapshot.generatedAt)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshClicked(_:)), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let reset = NSMenuItem(title: "移回主屏幕右上角", action: #selector(resetPositionClicked(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出服务状态面板", action: #selector(quitClicked(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func placeDefault(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else { return }
        let x = visible.maxX - panel.frame.width - 24
        let y = visible.maxY - panel.frame.height - 26
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func constrainToVisibleScreen(_ panel: NSPanel) {
        guard !NSScreen.screens.isEmpty else { return }
        let current = panel.frame
        let target = NSScreen.screens.max { left, right in
            intersectionArea(left.visibleFrame, current) < intersectionArea(right.visibleFrame, current)
        } ?? NSScreen.main ?? NSScreen.screens[0]

        let visible = target.visibleFrame.insetBy(dx: 8, dy: 8)
        let maxX = max(visible.minX, visible.maxX - current.width)
        let maxY = max(visible.minY, visible.maxY - current.height)
        let x = min(max(current.minX, visible.minX), maxX)
        let y = min(max(current.minY, visible.minY), maxY)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
