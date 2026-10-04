import Foundation
import CoreGraphics

enum RemoteTouchAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
}

enum AndroidKeyCode: UInt16 {
    case home = 3
    case back = 4
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case appSwitch = 187
}

enum ControlPacket {
    static func shouldRequestFrameFeedback(for legacyPayload: Data) -> Bool {
        guard let eventType = legacyPayload.first else { return false }
        switch eventType {
        case 0x00:
            return legacyPayload.dropFirst().first == RemoteTouchAction.up.rawValue
        case 0x02:
            return legacyPayload.dropFirst().first != RemoteTouchAction.move.rawValue
        case 0x09, 0x0B:
            return true
        default:
            return false
        }
    }

    static func envelope(
        legacyPayload: Data,
        sequence: UInt64,
        clientMonotonicMicroseconds: UInt64,
        requestsFrameFeedback: Bool
    ) -> Data {
        var data = Data(capacity: 20 + legacyPayload.count)
        data.append(0x66)
        data.append(0x01)
        data.append(requestsFrameFeedback ? 0x01 : 0x00)
        data.append(0x00)
        data.appendBigEndian(sequence)
        data.appendBigEndian(clientMonotonicMicroseconds)
        data.append(legacyPayload)
        return data
    }

    static func touch(
        action: RemoteTouchAction,
        pointerID: UInt8,
        x: UInt16,
        y: UInt16,
        pressure: UInt16,
        buttons: UInt8
    ) -> Data {
        var data = Data(capacity: 10)
        data.append(0x02)
        data.append(action.rawValue)
        data.append(pointerID)
        data.appendBigEndian(x)
        data.appendBigEndian(y)
        data.appendBigEndian(pressure)
        data.append(buttons)
        return data
    }

    static func key(action: RemoteTouchAction, code: AndroidKeyCode) -> Data {
        var data = Data(capacity: 4)
        data.append(0x00)
        data.append(action.rawValue)
        data.appendBigEndian(code.rawValue)
        return data
    }

    static func keyPress(_ code: AndroidKeyCode) -> [Data] {
        [
            key(action: .down, code: code),
            key(action: .up, code: code)
        ]
    }

    static var rotate: Data {
        Data([0x0B])
    }

    static var requestKeyframe: Data {
        Data([0x10])
    }

    static func requestClipboard(copyKey: UInt8 = 0) -> Data {
        Data([0x08, copyKey])
    }

    static func setClipboard(
        text: String,
        sequence: UInt64,
        paste: Bool
    ) -> Data {
        let textData = Data(text.utf8)
        var data = Data(capacity: 14 + textData.count)
        data.append(0x09)
        data.appendBigEndian(sequence)
        data.append(paste ? 1 : 0)
        data.appendBigEndian(UInt32(clamping: textData.count))
        data.append(textData)
        return data
    }

    static func scroll(
        x: UInt16,
        y: UInt16,
        horizontal: Int16,
        vertical: Int16
    ) -> Data {
        var data = Data(capacity: 10)
        data.append(0x03)
        data.appendBigEndian(x)
        data.appendBigEndian(y)
        data.appendBigEndian(UInt16(bitPattern: horizontal))
        data.appendBigEndian(UInt16(bitPattern: vertical))
        data.append(0)
        return data
    }
}

struct ControlAcknowledgement {
    let sequence: UInt64
    let clientMonotonicMicroseconds: UInt64
    let gatewayReceivedMicroseconds: UInt64
    let driverWriteMicroseconds: UInt64
    let status: UInt8
    let legacyType: UInt8
}

struct ControlFrameFeedback {
    let status: UInt8
    let legacyType: UInt8
    let sequence: UInt64
    let clientMonotonicMicroseconds: UInt64
    let gatewayReceivedMicroseconds: UInt64
    let driverWriteMicroseconds: UInt64
    let frameSeenMicroseconds: UInt64
    let framePresentationTimestamp: UInt64
}

enum ControlTelemetryFeedback {
    case acknowledgement(ControlAcknowledgement)
    case frame(ControlFrameFeedback)

    static func decode(_ data: Data) -> ControlTelemetryFeedback? {
        guard data.count >= 2, data.byte(at: 1) == 0x01 else { return nil }
        switch data.byte(at: 0) {
        case 0x67:
            guard data.count == 36,
                  let status = data.byte(at: 2),
                  let legacyType = data.byte(at: 3),
                  let sequence = data.uint64BigEndian(at: 4),
                  let clientTime = data.uint64BigEndian(at: 12),
                  let gatewayTime = data.uint64BigEndian(at: 20),
                  let driverTime = data.uint64BigEndian(at: 28)
            else {
                return nil
            }
            return .acknowledgement(
                ControlAcknowledgement(
                    sequence: sequence,
                    clientMonotonicMicroseconds: clientTime,
                    gatewayReceivedMicroseconds: gatewayTime,
                    driverWriteMicroseconds: driverTime,
                    status: status,
                    legacyType: legacyType
                )
            )
        case 0x68:
            guard data.count == 52,
                  let status = data.byte(at: 2),
                  let legacyType = data.byte(at: 3),
                  let sequence = data.uint64BigEndian(at: 4),
                  let clientTime = data.uint64BigEndian(at: 12),
                  let gatewayTime = data.uint64BigEndian(at: 20),
                  let driverTime = data.uint64BigEndian(at: 28),
                  let frameSeenTime = data.uint64BigEndian(at: 36),
                  let framePTS = data.uint64BigEndian(at: 44)
            else {
                return nil
            }
            return .frame(
                ControlFrameFeedback(
                    status: status,
                    legacyType: legacyType,
                    sequence: sequence,
                    clientMonotonicMicroseconds: clientTime,
                    gatewayReceivedMicroseconds: gatewayTime,
                    driverWriteMicroseconds: driverTime,
                    frameSeenMicroseconds: frameSeenTime,
                    framePresentationTimestamp: framePTS
                )
            )
        default:
            return nil
        }
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    fileprivate func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }

    fileprivate func uint64BigEndian(at offset: Int) -> UInt64? {
        guard offset >= 0, count - offset >= 8 else { return nil }
        var value: UInt64 = 0
        for byteOffset in offset..<(offset + 8) {
            guard let byte = byte(at: byteOffset) else { return nil }
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
