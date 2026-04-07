import Foundation
import CLibUSB

/// IEEE 1284.4 / DOT4 channel multiplexing protocol for HP printers.
/// Exact byte sequences from HPLIP source (io/hpmud/dot4.c).
class DOT4Channel {
    private let deviceHandle: OpaquePointer
    private let endpointIn: UInt8
    private let endpointOut: UInt8
    private let timeout: UInt32 = 5000

    private var scanSocketID: UInt8 = 0
    private var channelOpen = false

    // DOT4 command codes — EXACT values from HPLIP mlc.h
    private static let INIT: UInt8         = 0x00  // reply = 0x80
    private static let OPEN_CHANNEL: UInt8 = 0x01  // reply = 0x81
    private static let CLOSE_CHANNEL: UInt8 = 0x02 // reply = 0x82
    private static let CREDIT: UInt8       = 0x03  // reply = 0x83
    private static let CREDIT_REQUEST: UInt8 = 0x04 // reply = 0x84
    private static let EXIT: UInt8         = 0x08
    private static let GET_SOCKET: UInt8   = 0x09  // reply = 0x89
    private static let ERROR: UInt8        = 0x7F

    private static let REPLY_BIT: UInt8    = 0x80
    private static let REVISION: UInt8     = 0x20

    init(deviceHandle: OpaquePointer, endpointIn: UInt8, endpointOut: UInt8) {
        self.deviceHandle = deviceHandle
        self.endpointIn = endpointIn
        self.endpointOut = endpointOut
    }

    // MARK: - Public API

    func openScanChannel() throws {
        log("=== DOT4 Init ===")

        // Step 1: Init
        try dot4Init()

        // Step 2: GetSocket for scan service
        let serviceNames = ["HP-LEDM-SCAN", "HP-SCAN", "HP-MARVELL-SCAN", "HP-SOAP-SCAN"]
        var socketID: UInt8 = 0

        for name in serviceNames {
            log("GetSocket '\(name)'...")
            do {
                socketID = try getSocket(serviceName: name)
                log("  → socket ID = \(socketID)")
                break
            } catch {
                log("  → failed: \(error)")
            }
        }

        guard socketID != 0 else {
            throw DOT4Error.noScanService
        }
        scanSocketID = socketID

        // Step 3: OpenChannel
        try openChannel(socketID: socketID)

        // Step 4: Credit
        try grantCredit(socketID: socketID, credit: 0xFFFF)

        channelOpen = true
        log("=== Scan channel OPEN on socket \(socketID) ===")
    }

    func closeScanChannel() {
        guard channelOpen else { return }
        try? closeChannel(socketID: scanSocketID)
        channelOpen = false
    }

    var isOpen: Bool { channelOpen }

    /// Send data wrapped in DOT4 frame
    func sendOnChannel(_ data: Data) throws {
        guard channelOpen else { throw DOT4Error.channelNotOpen }

        let totalLen = 6 + data.count
        var frame: [UInt8] = [
            scanSocketID,                    // psid
            scanSocketID,                    // ssid (same as psid for data)
            UInt8((totalLen >> 8) & 0xFF),   // length high
            UInt8(totalLen & 0xFF),          // length low
            0x00,                            // credit (piggyback)
            0x00                             // control
        ]
        frame.append(contentsOf: data)

        try bulkWrite(Data(frame))
    }

    /// Receive data, strip DOT4 header
    func receiveFromChannel(maxSize: Int = 65536) throws -> Data {
        guard channelOpen else { throw DOT4Error.channelNotOpen }

        let raw = try bulkRead(maxSize: maxSize)
        guard raw.count >= 6 else { return raw }

        let psid = raw[0]
        let ssid = raw[1]

        // Data packet for our channel
        if psid == scanSocketID && ssid == scanSocketID {
            return Data(raw[6...])
        }

        // Control packet on channel 0
        if psid == 0 && ssid == 0 && raw.count >= 7 {
            let cmd = raw[6]
            log("Control message: cmd=0x\(String(cmd, radix: 16))")

            // Auto-handle credit requests
            if cmd == Self.CREDIT_REQUEST || cmd == (Self.CREDIT_REQUEST | Self.REPLY_BIT) {
                try? grantCredit(socketID: scanSocketID, credit: 0xFFFF)
            }

            // Read again for actual data
            return try receiveFromChannel(maxSize: maxSize)
        }

        // Unknown packet — return raw payload after header
        return Data(raw[6...])
    }

    // MARK: - DOT4 Commands (exact HPLIP byte sequences)

    private func dot4Init() throws {
        // Exact: 00 00 00 08 01 00 00 20
        let packet: [UInt8] = [
            0x00, 0x00,       // psid=0, ssid=0 (command channel)
            0x00, 0x08,       // length=8
            0x01,             // credit=1
            0x00,             // control=0
            Self.INIT,        // cmd=0x00
            Self.REVISION     // rev=0x20
        ]

        log("TX Init: \(hex(packet))")
        try bulkWrite(Data(packet))

        let reply = try bulkRead(maxSize: 256)
        log("RX Init: \(hex(Array(reply)))")

        // Expect 9 bytes: 00 00 00 09 01 00 80 00 20
        guard reply.count >= 9 else {
            throw DOT4Error.invalidReply("Init reply too short: \(reply.count) bytes, data: \(hex(Array(reply)))")
        }

        let replyCmd = reply[6]
        guard replyCmd == (Self.INIT | Self.REPLY_BIT) else {
            throw DOT4Error.invalidReply("Expected 0x80, got 0x\(String(replyCmd, radix: 16)), full: \(hex(Array(reply)))")
        }

        let result = reply[7]
        guard result == 0 else {
            throw DOT4Error.invalidReply("Init result=\(result) (expected 0)")
        }

        log("DOT4 Init OK, revision=0x\(String(reply[8], radix: 16))")
    }

    private func getSocket(serviceName: String) throws -> UInt8 {
        let nameBytes = Array(serviceName.utf8)
        let totalLen = 6 + 1 + nameBytes.count  // header + cmd + name (NO length prefix)

        var packet: [UInt8] = [
            0x00, 0x00,                          // command channel
            UInt8((totalLen >> 8) & 0xFF),
            UInt8(totalLen & 0xFF),
            0x01,                                 // credit=1
            0x00,                                 // control
            Self.GET_SOCKET                       // cmd=0x09
        ]
        packet.append(contentsOf: nameBytes)

        log("TX GetSocket[\(serviceName)]: \(hex(packet))")
        try bulkWrite(Data(packet))

        let reply = try bulkRead(maxSize: 256)
        log("RX GetSocket: \(hex(Array(reply)))")

        // Expect: header(6) + cmd(0x89) + result(0x00) + socketID
        guard reply.count >= 9 else {
            throw DOT4Error.invalidReply("GetSocket reply too short: \(reply.count)")
        }

        let replyCmd = reply[6]
        guard replyCmd == (Self.GET_SOCKET | Self.REPLY_BIT) else {
            throw DOT4Error.invalidReply("Expected 0x89, got 0x\(String(replyCmd, radix: 16))")
        }

        let result = reply[7]
        let socketID = reply[8]

        guard result == 0 && socketID != 0 else {
            throw DOT4Error.serviceNotFound(serviceName)
        }

        return socketID
    }

    private func openChannel(socketID: UInt8) throws {
        // 15 bytes total
        let packet: [UInt8] = [
            0x00, 0x00,             // command channel
            0x00, 0x0F,             // length=15
            0x01,                   // credit=1
            0x00,                   // control
            Self.OPEN_CHANNEL,      // cmd=0x01
            socketID,               // psocket
            socketID,               // ssocket
            0x40, 0x00,             // maxP2S = 16384 (0x4000)
            0x40, 0x00,             // maxS2P = 16384 (0x4000)
            0xFF, 0xFF              // maxCredit = 65535
        ]

        log("TX OpenChannel[\(socketID)]: \(hex(packet))")
        try bulkWrite(Data(packet))

        let reply = try bulkRead(maxSize: 256)
        log("RX OpenChannel: \(hex(Array(reply)))")

        guard reply.count >= 7 else {
            throw DOT4Error.invalidReply("OpenChannel reply too short: \(reply.count)")
        }

        let replyCmd = reply[6]
        guard replyCmd == (Self.OPEN_CHANNEL | Self.REPLY_BIT) else {
            throw DOT4Error.invalidReply("Expected 0x81, got 0x\(String(replyCmd, radix: 16))")
        }

        log("Channel \(socketID) opened")
    }

    private func closeChannel(socketID: UInt8) throws {
        let packet: [UInt8] = [
            0x00, 0x00,
            0x00, 0x09,            // length=9
            0x00,
            0x00,
            Self.CLOSE_CHANNEL,    // cmd=0x02
            socketID,              // psocket
            socketID               // ssocket
        ]

        try bulkWrite(Data(packet))
        _ = try? bulkRead(maxSize: 256)
    }

    private func grantCredit(socketID: UInt8, credit: UInt16) throws {
        let packet: [UInt8] = [
            0x00, 0x00,
            0x00, 0x0B,             // length=11
            0x00,
            0x00,
            Self.CREDIT,            // cmd=0x03
            socketID,               // psocket
            socketID,               // ssocket
            UInt8((credit >> 8) & 0xFF),
            UInt8(credit & 0xFF)
        ]

        log("TX Credit[\(socketID)]: \(hex(packet))")
        try bulkWrite(Data(packet))

        let reply = try bulkRead(maxSize: 256)
        log("RX Credit: \(hex(Array(reply)))")
    }

    // MARK: - USB I/O

    private func bulkWrite(_ data: Data) throws {
        var bytes = Array(data)
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(deviceHandle, endpointOut, &bytes, Int32(bytes.count), &transferred, timeout)
        guard rc == 0 else {
            throw DOT4Error.usbWriteFailed(code: rc)
        }
    }

    private func bulkRead(maxSize: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxSize)
        var transferred: Int32 = 0
        let rc = libusb_bulk_transfer(deviceHandle, endpointIn, &buffer, Int32(maxSize), &transferred, timeout)
        guard rc == 0 && transferred > 0 else {
            if rc == LIBUSB_ERROR_TIMEOUT.rawValue {
                throw DOT4Error.timeout
            }
            throw DOT4Error.usbReadFailed(code: rc, transferred: transferred)
        }
        return Data(buffer[0..<Int(transferred)])
    }

    // MARK: - Helpers

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func log(_ message: String) {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PaperCat.log")
        let line = "[\(Date())] [DOT4] \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}

enum DOT4Error: LocalizedError {
    case noScanService
    case channelNotOpen
    case serviceNotFound(String)
    case invalidReply(String)
    case usbWriteFailed(code: Int32)
    case usbReadFailed(code: Int32, transferred: Int32)
    case timeout

    var errorDescription: String? {
        switch self {
        case .noScanService: return "No scan service found on device"
        case .channelNotOpen: return "DOT4 scan channel not open"
        case .serviceNotFound(let s): return "Service '\(s)' not found"
        case .invalidReply(let d): return "Invalid DOT4 reply: \(d)"
        case .usbWriteFailed(let c): return "USB write failed (code \(c))"
        case .usbReadFailed(let c, let t): return "USB read failed (code \(c), transferred \(t))"
        case .timeout: return "DOT4 timeout"
        }
    }
}
