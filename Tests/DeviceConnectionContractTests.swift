import Foundation

// Run with swiftc APIModels.swift Tests/DeviceConnectionContractTests.swift.
@main
enum DeviceConnectionContractTests {
    static func main() throws {
        let decoder = JSONDecoder()
        func payload(device: String = "phone-a", request: String = "request-a",
                     configured: Bool = true, wifi: Bool = true,
                     state: String = "ready", transport: String = "usb",
                     instance: String = "server-a", generation: UInt64 = 42) -> Data {
            Data("""
            {"type":"transport_status","request_id":"\(request)","status":"ok",
             "connection":{"device_id":"\(device)","wireless_configured":\(configured),
              "usb_available":true,"wifi_available":\(wifi),"preference":"auto",
              "active_transport":"\(transport)","state":"\(state)",
              "instance_id":"\(instance)","generation":\(generation)}}
            """.utf8)
        }
        func decode(_ data: Data) throws -> DeviceConnectionResponse {
            try decoder.decode(DeviceConnectionResponse.self, from: data)
                .validated(requestID: "request-a", deviceID: "phone-a")
        }
        let ready = try decode(payload()).connection!
        precondition(ready.wirelessConfigured && ready.wifiAvailable)
        precondition(ready.activeTransport == "usb" && ready.generation == 42)

        let temporarilyOffline = try decode(payload(wifi: false)).connection!
        precondition(temporarilyOffline.wirelessConfigured && !temporarilyOffline.wifiAvailable,
                     "Configured capability must survive a temporary Wi-Fi outage")
        let unsupported = try decode(payload(configured: false, wifi: false)).connection!
        precondition(!unsupported.wirelessConfigured)
        let switching = try decode(payload(state: "switching", transport: "none")).connection!
        precondition(switching.isSwitching && switching.transportLabel == "正在切换")

        for invalid in [payload(device: "other-phone"), payload(request: "stale-request"),
                        Data("{\"status\":\"error\",\"stage\":\"webrtc_init\"}".utf8)] {
            do {
                _ = try decode(invalid)
                fatalError("Cross-device, stale, and legacy responses must be rejected")
            } catch {}
        }
        let restarted = try decode(payload(instance: "server-b", generation: 1)).connection!
        precondition(restarted.canReplace(ready, requestSequence: 5, lastAcceptedRequestSequence: 4),
                     "A gateway restart must not leave the UI permanently stale")
        precondition(!ready.canReplace(restarted, requestSequence: 3, lastAcceptedRequestSequence: 5),
                     "A delayed response from before restart must not restore the old process")
        let older = try decode(payload(generation: 41)).connection!
        precondition(!older.canReplace(ready, requestSequence: 6, lastAcceptedRequestSequence: 5))
        precondition(!ready.canReplace(ready, requestSequence: 4, lastAcceptedRequestSequence: 5))
        let newer = try decode(payload(generation: 43)).connection!
        precondition(newer.canReplace(ready, requestSequence: 4, lastAcceptedRequestSequence: 5),
                     "An accepted switch may finish after a later read observed the previous generation")
        print("12 connection contract checks passed")
    }
}
