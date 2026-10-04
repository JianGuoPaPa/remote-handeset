import Foundation

enum MicrophonePacket {
    static let sampleRate = 48_000
    static let samplesPerPacket = 960
    static let bytesPerPacket = samplesPerPacket * MemoryLayout<Int16>.size
    static let headerLength = 28

    private enum Flag: UInt8 {
        case start = 0x01
        case stop = 0x02
        case data = 0x04
    }

    static func start(streamID: UInt32, timestampMicroseconds: UInt64) -> Data {
        make(
            flag: .start,
            streamID: streamID,
            sequence: 0,
            timestampMicroseconds: timestampMicroseconds,
            pcm: nil
        )
    }

    static func data(
        streamID: UInt32,
        sequence: UInt32,
        timestampMicroseconds: UInt64,
        pcm: Data
    ) -> Data? {
        guard streamID != 0,
              sequence != 0,
              pcm.count == bytesPerPacket else { return nil }
        return make(
            flag: .data,
            streamID: streamID,
            sequence: sequence,
            timestampMicroseconds: timestampMicroseconds,
            pcm: pcm
        )
    }

    static func stop(
        streamID: UInt32,
        sequence: UInt32,
        timestampMicroseconds: UInt64
    ) -> Data {
        make(
            flag: .stop,
            streamID: streamID,
            sequence: sequence,
            timestampMicroseconds: timestampMicroseconds,
            pcm: nil
        )
    }

    private static func make(
        flag: Flag,
        streamID: UInt32,
        sequence: UInt32,
        timestampMicroseconds: UInt64,
        pcm: Data?
    ) -> Data {
        var packet = Data(capacity: headerLength + (pcm?.count ?? 0))
        packet.append(contentsOf: [0x49, 0x55, 0x4D, 0x43]) // IUMC
        packet.append(1)
        packet.append(flag.rawValue)
        packet.appendBigEndian(UInt16(headerLength))
        packet.appendBigEndian(streamID)
        packet.appendBigEndian(sequence)
        packet.appendBigEndian(timestampMicroseconds)
        packet.appendBigEndian(
            flag == .data ? UInt16(samplesPerPacket) : UInt16(0)
        )
        packet.append(1) // mono
        packet.append(1) // signed 16-bit little-endian PCM
        if let pcm { packet.append(pcm) }
        return packet
    }
}

struct MicrophoneStateFeedback: Decodable {
    let version: Int
    let type: String
    let state: String
    let streamID: UInt32?
    let generation: UInt64?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case state
        case streamID
        case generation
    }
}

struct MicrophoneDemandMessage: Decodable {
    enum State: String, Decodable {
        case active
        case idle
    }

    let version: Int
    let type: String
    let state: State
    let generation: UInt64

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case state
        case generation
    }

    var isValid: Bool {
        version == 1 && type == "microphoneDemand"
    }
}

private struct MicrophoneDemandAcceptance: Encodable {
    let version = 1
    let type = "microphoneDemandAccept"
    let generation: UInt64

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case type
        case generation
    }
}

extension MicrophonePacket {
    /// UTF-8 JSON sent on the reliable microphone-control DataChannel before
    /// microphone RTP is considered accepted for a specific demand generation.
    static func demandAcceptance(generation: UInt64) -> Data? {
        try? JSONEncoder().encode(
            MicrophoneDemandAcceptance(generation: generation)
        )
    }
}
