import CoreBluetooth
import Foundation

// Nano Cortex BLE protocol.
//
// Source: reverse-engineering in github.com/DrD85/nano-cortex-editor (index.html, MIT),
// which states the capture messages were decoded from Cortex Cloud 2.8.3 traffic and
// have NOT been verified on hardware by its author. Everything here is therefore
// best-effort; the BLE monitor (Debug menu) logs every packet to help adjust it.
//
// Transport: one GATT service (0xA002, 0xA003 on some firmwares), write characteristic
// 0xC304 (write with response) and notify characteristic 0xC305.
//
// Framing of a complete single-packet message:
//   [len = frame.count - 2] [0xC0] [protobuf payload] [u32 LE message type]
// Long replies are split: byte 1 carries 0x40 on the first packet, 0x80 on the last;
// the payloads after the first two bytes are concatenated and end with the u32 type.

enum NanoBLEUUID {
    static let services: [CBUUID] = [CBUUID(string: "A002"), CBUUID(string: "A003")]
    static let write = CBUUID(string: "C304")
    static let notify = CBUUID(string: "C305")

    /// Advertised name is not documented; the editor matches /cortex|nano/i.
    static func nameMatches(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return n.contains("nano") || n.contains("cortex")
    }
}

/// Message type numbers (u32 trailer).
enum NanoMessageType: UInt32 {
    case stateRequest = 1
    case stateResponse = 2
    case saveCapture = 13
    case saveCaptureResponse = 14
    case value = 26                 // CAPTURE IN gain / OUTPUT level (context 1 = capture)
    case button = 27                // 0 EXIT, 1 CAPTURE, 2 SAVE
    case setPresetSlotsRequest = 29 // sent by the Nano on preset change: must be acked with 30
    case setPresetSlotsResponse = 30
    case startTraining = 39
    case trainingProgress = 40      // field 3: 0...255
    case trainingDone = 41
    case abCompare = 42
    case compareCab = 43
    case metering = 64              // field 3: 0 CAPTURE IN, 1 OUTPUT, 2 expression; field 4: 0...255
    case startCapture = 73          // enter capture mode
    case setCaptureSlotContentRequest = 80
    case setCaptureSlotContentResponse = 81
    case captureStateRequest = 87
    case captureState = 88
    case captureSanity = 93         // field 3: 0 no/low signal, 1 too hot
}

// MARK: - Protobuf (minimal)

enum ProtoValue: Equatable {
    case varint(UInt64)
    case fixed64(Data)
    case bytes(Data)
    case fixed32(Data)

    var int: Int? { if case .varint(let v) = self { return Int(truncatingIfNeeded: v) } else { return nil } }
    var data: Data? { if case .bytes(let d) = self { return d } else { return nil } }
    var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}

struct ProtoFields {
    private(set) var storage: [Int: [ProtoValue]] = [:]

    subscript(field: Int) -> ProtoValue? { storage[field]?.first }
    func int(_ field: Int, default def: Int = 0) -> Int { self[field]?.int ?? def }

    static func parse(_ bytes: Data) -> ProtoFields {
        var fields = ProtoFields()
        let b = [UInt8](bytes)
        var i = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let tag = readVarint() else { break }
            let field = Int(tag >> 3)
            let wire = tag & 7
            switch wire {
            case 0:
                guard let v = readVarint() else { return fields }
                fields.storage[field, default: []].append(.varint(v))
            case 1:
                guard i + 8 <= b.count else { return fields }
                fields.storage[field, default: []].append(.fixed64(Data(b[i..<i + 8])))
                i += 8
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return fields }
                fields.storage[field, default: []].append(.bytes(Data(b[i..<i + Int(len)])))
                i += Int(len)
            case 5:
                guard i + 4 <= b.count else { return fields }
                fields.storage[field, default: []].append(.fixed32(Data(b[i..<i + 4])))
                i += 4
            default:
                return fields
            }
        }
        return fields
    }
}

enum Proto {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    static func varintField(_ field: Int, _ value: Int) -> [UInt8] {
        // Negative int32 values are sign-extended to 10 bytes, as protobuf does.
        [UInt8(field << 3)] + varint(UInt64(bitPattern: Int64(value)))
    }

    static func bytesField(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        [UInt8(field << 3 | 2)] + varint(UInt64(bytes.count)) + bytes
    }

    static func stringField(_ field: Int, _ text: String) -> [UInt8] {
        bytesField(field, Array(text.utf8))
    }
}

// MARK: - Frames

struct NanoMessage {
    let type: UInt32
    let payload: Data
    var fields: ProtoFields { ProtoFields.parse(payload) }
    var knownType: NanoMessageType? { NanoMessageType(rawValue: type) }
}

enum NanoFrame {
    static func build(_ type: NanoMessageType, _ payload: [UInt8] = []) -> Data {
        var frame: [UInt8] = [0, 0xC0] + payload
        let t = type.rawValue
        frame += [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF)]
        frame[0] = UInt8(truncatingIfNeeded: frame.count - 2)
        return Data(frame)
    }

    static func hex(_ data: Data, limit: Int = 64) -> String {
        let s = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? s + " …(\(data.count) B)" : s
    }

    static func fromHex(_ text: String) -> Data? {
        let clean = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out = Data()
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}

/// Reassembles notifications into complete messages.
struct NanoReassembler {
    private var buffer: [UInt8] = []
    private var receiving = false

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        receiving = false
    }

    /// Returns a message when `packet` completes one.
    mutating func feed(_ packet: Data) -> NanoMessage? {
        let b = [UInt8](packet)
        guard b.count >= 2 else { return nil }

        if b[1] == 0xC0 {
            // Complete single packet: [len][C0][payload][u32 type]
            guard b.count >= 6 else { return nil }
            let n = b.count
            let type = UInt32(b[n - 4]) | UInt32(b[n - 3]) << 8 | UInt32(b[n - 2]) << 16 | UInt32(b[n - 1]) << 24
            return NanoMessage(type: type, payload: Data(b[2..<(n - 4)]))
        }

        let first = b[1] & 0x40 != 0
        let last = b[1] & 0x80 != 0
        if first {
            buffer.removeAll(keepingCapacity: true)
            receiving = true
        }
        guard receiving else { return nil }
        buffer.append(contentsOf: b[2...])
        guard last else { return nil }
        receiving = false
        guard buffer.count >= 4 else { return nil }
        let n = buffer.count
        let type = UInt32(buffer[n - 4]) | UInt32(buffer[n - 3]) << 8 | UInt32(buffer[n - 2]) << 16 | UInt32(buffer[n - 1]) << 24
        let message = NanoMessage(type: type, payload: Data(buffer[0..<(n - 4)]))
        buffer.removeAll(keepingCapacity: true)
        return message
    }
}

// MARK: - Commands

enum NanoCommand {
    /// Current preset state request (captured verbatim by nano-cortex-editor).
    static let stateRequest = NanoFrame.fromHex("0C C0 08 03 18 01 20 01 28 01 01 00 00 00")!

    /// Ack for a preset change reported by the Nano (SetPresetSlotsResponse { 4: Success }).
    static let presetChangeAck = NanoFrame.build(.setPresetSlotsResponse, [0x20, 0x01])

    /// Enter capture mode ("New Neural Capture").
    static let enterCaptureMode = NanoFrame.build(.startCapture)

    /// Start the capture (training) once levels are set.
    static let startTraining = NanoFrame.build(.startTraining)

    /// "Exit" button: goes back one step in capture mode.
    static let exitStep = NanoFrame.build(.button, [0x20, 0x01])

    static let captureStateRequest = NanoFrame.build(.captureStateRequest)

    enum CaptureValue: Int {
        case captureInGain = 0 // CAPTURE IN, 0...+24 dB
        case outputLevel = 1   // OUTPUT LEVEL, -60...+12 dB
    }

    /// Value message with context 1 (capture). `raw` 0...255.
    static func setCaptureValue(_ which: CaptureValue, raw: Int) -> Data {
        let v = max(0, min(255, raw))
        return NanoFrame.build(.value, [0x18, UInt8(which.rawValue)] + Proto.varintField(4, v) + [0x28, 0x01])
    }

    /// Save the finished capture into "My Neural Captures".
    static func saveCapture(name: String, firmwareType: String) -> Data {
        let record = Proto.stringField(2, name) + Proto.stringField(6, firmwareType) + Proto.stringField(10, "guitar")
        return NanoFrame.build(.saveCapture, Proto.bytesField(4, record))
    }

    /// Load a saved capture (by the id returned in SaveCaptureResponse) into slot 1...25.
    static func setCaptureSlot(_ slot: Int, captureID: Data) -> Data {
        NanoFrame.build(.setCaptureSlotContentRequest, Proto.varintField(3, slot - 1) + Proto.bytesField(5, [UInt8](captureID)))
    }

    /// Cortex Cloud slider mapping (from nano-cortex-editor): value = min + (max-min) * p^(1/skew).
    static func captureInDB(raw: Int) -> Double {
        let p = Double(max(0, min(255, raw))) / 255
        return 24 * pow(p, 1 / 0.9)
    }

    static func outputLevelDB(raw: Int) -> Double {
        let p = Double(max(0, min(255, raw))) / 255
        return -60 + 72 * pow(p, 1 / 3.8018)
    }
}

// MARK: - Decoded events

enum NanoEvent: Equatable {
    case state(captureMode: Bool, firmware: String?, captureInRaw: Int?, outputLevelRaw: Int?)
    case meter(channel: Int, raw: Int)
    case button(Int)
    case trainingProgress(raw: Int)
    case trainingDone
    case captureState(step: Int, progressRaw: Int)
    case sanity(status: Int)
    case saveResponse(ok: Bool, captureID: Data?, reason: String?)
    case slotResponse(ok: Bool)
    case captureValue(which: Int, raw: Int)
    case presetChanged
    case other(type: UInt32)

    static func decode(_ message: NanoMessage) -> NanoEvent {
        let f = message.fields
        switch message.knownType {
        case .stateResponse:
            let capture = f.int(23) == 1
            return .state(captureMode: capture,
                          firmware: f[24]?.string,
                          captureInRaw: capture ? min(255, f.int(3)) : nil,
                          outputLevelRaw: capture ? min(255, f.int(4)) : nil)
        case .metering: return .meter(channel: f.int(3), raw: f.int(4))
        case .button: return .button(f.int(3))
        case .trainingProgress: return .trainingProgress(raw: f.int(3))
        case .trainingDone: return .trainingDone
        case .captureState: return .captureState(step: f.int(3), progressRaw: f.int(4))
        case .captureSanity: return .sanity(status: f.int(3))
        case .saveCaptureResponse:
            return .saveResponse(ok: f.int(3) == 1, captureID: f[4]?.data, reason: f[5]?.string)
        case .setCaptureSlotContentResponse: return .slotResponse(ok: f.int(3) == 1)
        case .value:
            guard f.int(5) == 1 else { return .other(type: message.type) }
            return .captureValue(which: f.int(3), raw: f.int(4))
        case .setPresetSlotsRequest: return .presetChanged
        default: return .other(type: message.type)
        }
    }
}
