import Foundation
import Combine
import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

/// DDC/CI I2C communication service for external displays.
/// Supports two hardware paths:
///   - ARM64 (Apple Silicon): IOAVService via DCPAVServiceProxy
///   - x86_64 (Intel):        IOFramebuffer I2C via IOFBCopyI2CInterfaceForBus
/// All I2C operations run on a private background queue to avoid blocking UI.
final class DDCService: ObservableObject, @unchecked Sendable {
    static let shared = DDCService()

    // VCP feature codes (DDC/CI standard)
    static let brightnessVCP: UInt8 = 0x10
    static let contrastVCP: UInt8   = 0x12
    static let powerVCP: UInt8      = 0xD6

    private let ddcQueue = DispatchQueue(label: "com.freedisplay.ddc", qos: .userInitiated)

    private struct WriteKey: Hashable {
        let displayID: CGDirectDisplayID
        let command: UInt8
    }

    private var latestWriteValues: [WriteKey: UInt16] = [:]
    private var latestWriteCallbacks: [WriteKey: [(Bool) -> Void]] = [:]
    private var latestWriteActive: Set<WriteKey> = []
    private var latestWriteLastValues: [WriteKey: UInt16] = [:]

    // MARK: - VCP Read Cache (5-second TTL)

    private struct VCPCacheEntry {
        let current: UInt16
        let max: UInt16
        let timestamp: Date
        var isExpired: Bool { Date().timeIntervalSince(timestamp) > 5.0 }
    }

    private var vcpCache: [CGDirectDisplayID: [UInt8: VCPCacheEntry]] = [:]
    private let cacheLock = NSLock()

    // MARK: - IOAVService Cache (ARM64 only)

#if arch(arm64)
    private var avServiceCache: [CGDirectDisplayID: IOAVServiceRef] = [:]
    private let avServiceLock = NSLock()
#endif

    private init() {}

    // MARK: - ARM64 IOAVService Path

#if arch(arm64)
    // MARK: - ARM64 EDID-based AVService matching
    //
    // Ported from MonitorControl's Arm64DDC matching algorithm. Each DCPAVServiceProxy node is
    // paired with the EDID captured from the framebuffer node (AppleCLCD2 / IOMobileFramebufferShim)
    // that immediately precedes it in IORegistry traversal order (framebuffers always enumerate
    // before their AVService child), then scored against CoreDisplay's authoritative EDID
    // dictionary for each CGDirectDisplayID. This replaces comparing CGDisplayVendorNumber/
    // CGDisplayModelNumber against an ancestor-chain walk, which is unreliable for some monitors
    // and can silently swap DDC targets when 2+ external displays are connected.

    /// Mapping warning exposed to UI when more than one external display is connected
    /// and no EDID match could be found for one or more of them.
    @Published var mappingWarning: String? = nil

    private struct EDIDCandidate {
        var edidUUID: String = ""
        var ioDisplayLocation: String = ""
        var productName: String = ""
        var serialNumber: Int64 = 0
        var service: IOAVServiceRef?
        var serviceLocation: Int = 0
    }

    /// dlsym-loaded CoreDisplay private API: returns the authoritative EDID-derived
    /// info dictionary for a display (vendor/product IDs, manufacture date, image size, etc).
    /// Loaded at runtime (never linked) per project convention for private frameworks.
    private static let coreDisplayInfoDictionary: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?).self)
    }()

    /// Walks the whole IOService registry once, in registration order, pairing each
    /// DCPAVServiceProxy node with the EDID/location/product info captured from the framebuffer
    /// node (AppleCLCD2 / IOMobileFramebufferShim) that precedes it.
    private func collectEDIDCandidates() -> [EDIDCandidate] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            IORegistryGetRootEntry(kIOMainPortDefault),
            "IOService",
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        let framebufferNames: Set<String> = ["AppleCLCD2", "IOMobileFramebufferShim"]
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { nameBuf.deallocate() }

        var serviceLocation = 0
        var pending = EDIDCandidate()
        var candidates: [EDIDCandidate] = []

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard IORegistryEntryGetName(entry, nameBuf) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuf)

            if framebufferNames.contains(name) {
                serviceLocation += 1
                pending = EDIDCandidate(serviceLocation: serviceLocation)

                if let edidUUID = IORegistryEntryCreateCFProperty(
                    entry, "EDID UUID" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
                )?.takeRetainedValue() as? String {
                    pending.edidUUID = edidUUID
                }

                let pathBuf = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
                defer { pathBuf.deallocate() }
                if IORegistryEntryGetPath(entry, kIOServicePlane, pathBuf) == KERN_SUCCESS {
                    pending.ioDisplayLocation = String(cString: pathBuf)
                }

                if let attrs = IORegistryEntryCreateCFProperty(
                    entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
                )?.takeRetainedValue() as? NSDictionary,
                   let productAttrs = attrs["ProductAttributes"] as? NSDictionary {
                    if let productName = productAttrs["ProductName"] as? String {
                        pending.productName = productName
                    }
                    if let serial = productAttrs["SerialNumber"] as? Int64 {
                        pending.serialNumber = serial
                    }
                }
            } else if name == "DCPAVServiceProxy" {
                guard let location = IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
                )?.takeRetainedValue() as? String, location == "External" else { continue }
                guard let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { continue }
                var candidate = pending
                candidate.service = avService
                candidates.append(candidate)
            }
        }
        return candidates
    }

    /// Scores how well an EDID candidate (from IORegistry) matches a CGDirectDisplayID, using
    /// CoreDisplay's structured EDID dictionary as ground truth. Higher is better; 0 = no match.
    private func edidMatchScore(displayID: CGDirectDisplayID, candidate: EDIDCandidate) -> Int {
        guard let dictFn = Self.coreDisplayInfoDictionary,
              let dict = dictFn(displayID)?.takeRetainedValue() as NSDictionary? else { return 0 }

        var score = 0

        if !candidate.ioDisplayLocation.isEmpty,
           let location = dict[kIODisplayLocationKey] as? String,
           location == candidate.ioDisplayLocation {
            score += 10
        }

        if !candidate.productName.isEmpty,
           let nameList = dict["DisplayProductName"] as? [String: String],
           let name = nameList["en_US"] ?? nameList.first?.value,
           name.lowercased() == candidate.productName.lowercased() {
            score += 1
        }

        if candidate.serialNumber != 0,
           let serial = dict[kDisplaySerialNumber] as? Int64,
           serial == candidate.serialNumber {
            score += 1
        }

        if let year = dict[kDisplayYearOfManufacture] as? Int64,
           let week = dict[kDisplayWeekOfManufacture] as? Int64,
           let vendor = dict[kDisplayVendorID] as? Int64,
           let product = dict[kDisplayProductID] as? Int64,
           let vSize = dict[kDisplayVerticalImageSize] as? Int64,
           let hSize = dict[kDisplayHorizontalImageSize] as? Int64 {
            let edidUUID = candidate.edidUUID
            // (hex key, byte offset within the raw "EDID UUID" registry string)
            let fields: [(key: String, loc: Int)] = [
                (String(format: "%04x", UInt16(clamping: vendor)).uppercased(), 0),
                (String(format: "%02x", UInt8(clamping: product & 0xFF))
                    .appending(String(format: "%02x", UInt8(clamping: (product >> 8) & 0xFF))).uppercased(), 4),
                (String(format: "%02x", UInt8(clamping: week))
                    .appending(String(format: "%02x", UInt8(clamping: year - 1990))).uppercased(), 19),
                (String(format: "%02x", UInt8(clamping: hSize / 10))
                    .appending(String(format: "%02x", UInt8(clamping: vSize / 10))).uppercased(), 30),
            ]
            for field in fields where field.key != "0000" {
                guard let start = edidUUID.index(edidUUID.startIndex, offsetBy: field.loc, limitedBy: edidUUID.endIndex),
                      let end = edidUUID.index(start, offsetBy: 4, limitedBy: edidUUID.endIndex) else { continue }
                if edidUUID[start..<end] == field.key {
                    score += 1
                }
            }
        }

        return score
    }

    /// Greedily assigns each external display the highest-scoring, not-yet-taken EDID candidate.
    private func buildAVServiceMap(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: IOAVServiceRef] {
        let candidates = collectEDIDCandidates()
        guard !candidates.isEmpty else { return [:] }

        var scoredPairs: [(displayID: CGDirectDisplayID, candidate: EDIDCandidate, score: Int)] = []
        for displayID in displayIDs {
            for candidate in candidates {
                let score = edidMatchScore(displayID: displayID, candidate: candidate)
                guard score > 0 else { continue }
                scoredPairs.append((displayID, candidate, score))
            }
        }

        var result: [CGDirectDisplayID: IOAVServiceRef] = [:]
        var takenLocations: Set<Int> = []
        var takenDisplayIDs: Set<CGDirectDisplayID> = []
        for pair in scoredPairs.sorted(by: { $0.score > $1.score }) {
            guard !takenDisplayIDs.contains(pair.displayID),
                  !takenLocations.contains(pair.candidate.serviceLocation),
                  let service = pair.candidate.service else { continue }
            result[pair.displayID] = service
            takenDisplayIDs.insert(pair.displayID)
            takenLocations.insert(pair.candidate.serviceLocation)
        }

        let unmatchedIDs = displayIDs.filter { !takenDisplayIDs.contains($0) }
        let leftoverCandidates = candidates.filter { !takenLocations.contains($0.serviceLocation) }
        if unmatchedIDs.count == 1, leftoverCandidates.count == 1, let service = leftoverCandidates[0].service {
            // Unambiguous: exactly one unmatched display and one leftover candidate.
            result[unmatchedIDs[0]] = service
        } else if unmatchedIDs.count > 1 {
            let warning = "Multiple external displays: DDC may target wrong monitor (EDID matching failed)"
            #if DEBUG
            print("[DDCService] WARNING: \(warning)")
            #endif
            DispatchQueue.main.async { self.mappingWarning = warning }
        } else {
            DispatchQueue.main.async { self.mappingWarning = nil }
        }

        return result
    }

    /// Finds the IOAVService for the given display. Caches the result per display.
    /// Returns nil if no working AVService is found (built-in displays, or displays
    /// that don't support DDC over the Apple Silicon AV path).
    private func findAVService(for displayID: CGDirectDisplayID) -> IOAVServiceRef? {
        // Fast path: return cached service if present
        avServiceLock.lock()
        if let cached = avServiceCache[displayID] {
            avServiceLock.unlock()
            return cached
        }
        avServiceLock.unlock()

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        let externalIDs = (0..<Int(displayCount))
            .map { displayIDs[$0] }
            .filter { CGDisplayIsBuiltin($0) == 0 }
        guard !externalIDs.isEmpty else { return nil }

        let serviceMap = buildAVServiceMap(displayIDs: externalIDs)

        // Double-checked locking: another thread may have populated the cache while we
        // were walking the IORegistry without the lock held.
        avServiceLock.lock()
        defer { avServiceLock.unlock() }
        if let cached = avServiceCache[displayID] { return cached }
        for (extID, avService) in serviceMap {
            avServiceCache[extID] = avService
        }

        #if DEBUG
        if avServiceCache[displayID] != nil {
            print("[DDCService] ARM64: found IOAVService for display \(displayID) via EDID match")
        } else {
            print("[DDCService] ARM64: no IOAVService found for display \(displayID)")
        }
        #endif
        return avServiceCache[displayID]
    }

    /// Invalidates the cached IOAVService for the given display (e.g. after display reconnect).
    func invalidateAVServiceCache(for displayID: CGDirectDisplayID) {
        avServiceLock.lock()
        avServiceCache.removeValue(forKey: displayID)
        avServiceLock.unlock()
    }

    /// ARM64 DDC write: send a Set VCP command via IOAVService.
    /// Buffer layout (bytes sent after the device address / offset arguments):
    ///   [0x84, 0x03, vcpCode, valueHigh, valueLow, checksum]
    /// Checksum = XOR of 0x50 (0x51 XOR 0x01) with all preceding buffer bytes.
    private func arm64Write(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let avService = findAVService(for: displayID) else { return false }

        let valueHigh = UInt8((value >> 8) & 0xFF)
        let valueLow  = UInt8(value & 0xFF)
        // Checksum seed: 0x50 = 0x6E (DDC destination) XOR 0x51 (sub-address used by IOAVServiceWriteI2C)
        // then XOR with each byte in the payload.
        var checksum  = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, command, valueHigh, valueLow]
        for b in payload { checksum ^= b }

        var buf: [UInt8] = payload + [checksum]
        let ret = IOAVServiceWriteI2C(avService, 0x37, 0x51, &buf, UInt32(buf.count))
        #if DEBUG
        if ret == kIOReturnSuccess {
            print("[DDCService] ARM64 write VCP 0x\(String(command, radix: 16)) = \(value) OK")
        } else {
            print("[DDCService] ARM64 write VCP 0x\(String(command, radix: 16)) failed: \(ret)")
        }
        #endif
        return ret == kIOReturnSuccess
    }

    /// ARM64 DDC read: send a Get VCP request then read the response via IOAVService.
    /// Request layout: [0x82, 0x01, vcpCode, checksum]
    /// Response bytes 4-7 carry: [maxHigh, maxLow, curHigh, curLow]
    private func arm64Read(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let avService = findAVService(for: displayID) else { return nil }

        // Build and send the VCP Get Request packet
        var requestChecksum = UInt8(0x6E ^ 0x51)
        let requestPayload: [UInt8] = [0x82, 0x01, command]
        for b in requestPayload { requestChecksum ^= b }
        var requestBuf: [UInt8] = requestPayload + [requestChecksum]

        let writeRet = IOAVServiceWriteI2C(avService, 0x37, 0x51, &requestBuf, UInt32(requestBuf.count))
        guard writeRet == kIOReturnSuccess else {
            #if DEBUG
            print("[DDCService] ARM64 read request failed for VCP 0x\(String(command, radix: 16)): \(writeRet)")
            #endif
            return nil
        }

        // Wait for the display to prepare its DDC/CI reply (~40ms per spec)
        Thread.sleep(forTimeInterval: 0.04)

        // Read the VCP reply
        var replyBuf = [UInt8](repeating: 0, count: 12)
        let readRet = IOAVServiceReadI2C(avService, 0x37, 0x51, &replyBuf, UInt32(replyBuf.count))
        guard readRet == kIOReturnSuccess else {
            #if DEBUG
            print("[DDCService] ARM64 read reply failed for VCP 0x\(String(command, radix: 16)): \(readRet)")
            #endif
            return nil
        }

        // DDC/CI VCP reply format (IOAVService variant):
        //   replyBuf[0] = source address (0x6E)
        //   replyBuf[1] = length byte (0x88 = 0x80 | 8)
        //   replyBuf[2] = 0x02 (Get VCP Feature Reply opcode)
        //   replyBuf[3] = result code (0x00 = no error)
        //   replyBuf[4] = VCP opcode echo
        //   replyBuf[5] = VCP type code
        //   replyBuf[6] = max value high byte
        //   replyBuf[7] = max value low byte
        //   replyBuf[8] = current value high byte
        //   replyBuf[9] = current value low byte
        //  replyBuf[10] = checksum
        guard replyBuf.count >= 10 else { return nil }

        let maxVal = (UInt16(replyBuf[6]) << 8) | UInt16(replyBuf[7])
        let curVal = (UInt16(replyBuf[8]) << 8) | UInt16(replyBuf[9])
        #if DEBUG
        print("[DDCService] ARM64 read VCP 0x\(String(command, radix: 16)): cur=\(curVal) max=\(maxVal)")
        #endif
        return (current: curVal, max: maxVal)
    }
#endif

    // MARK: - Intel (x86_64) IOFramebuffer Path

    /// Finds the IOFramebuffer service for a given external display.
    /// Returns a retained io_service_t — caller must IOObjectRelease.
    private func framebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        // Strategy 1: Use CGDisplayIOServicePort (deprecated but functional on macOS 15)
        let servicePort = CGDisplayIOServicePort(displayID)
        if servicePort != MACH_PORT_NULL && servicePort != 0 {
            var parent: io_service_t = 0
            if IORegistryEntryGetParentEntry(servicePort, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 {
                return parent
            }
        }

        // Strategy 2: Fallback to vendor+model matching
        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }

            guard let cfDict = IODisplayCreateInfoDictionary(
                service,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? NSDictionary else { continue }

            // Extract vendor and model IDs (may be stored as UInt32 or Int)
            let sVendor: UInt32
            let sModel: UInt32
            if let v = cfDict["DisplayVendorID"] as? UInt32 { sVendor = v }
            else if let v = cfDict["DisplayVendorID"] as? Int {
                sVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let m = cfDict["DisplayProductID"] as? UInt32 { sModel = m }
            else if let m = cfDict["DisplayProductID"] as? Int {
                sModel = UInt32(bitPattern: Int32(truncatingIfNeeded: m))
            } else { continue }

            guard sVendor == vendor && sModel == model else { continue }

            // Walk up to parent IOFramebuffer
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else { continue }
            // Caller must release parent
            return parent
        }
        return nil
    }

    // MARK: - DDC Checksum (Intel path)

    /// Computes DDC/CI checksum: XOR of destination address + all buffer bytes.
    private func ddcChecksum(destAddress: UInt8, bytes: [UInt8]) -> UInt8 {
        var cs: UInt8 = destAddress
        for b in bytes { cs ^= b }
        return cs
    }

    // MARK: - Synchronous DDC I/O (called on ddcQueue)

    /// Synchronous DDC write (VCP Set). Returns true on success.
    /// On ARM64 uses the IOAVService path; on x86_64 uses the IOFramebuffer I2C path.
    private func writeSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
#if arch(arm64)
        // ARM64 primary path
        if arm64Write(displayID: displayID, command: command, value: value) {
            return true
        }
        #if DEBUG
        print("[DDCService] writeSynchronous ARM64: failed for display \(displayID) VCP 0x\(String(command, radix: 16))")
        #endif
        return false
#else
        // Intel fallback path
        return intelWriteSynchronous(displayID: displayID, command: command, value: value)
#endif
    }

    /// Synchronous DDC read (VCP Get). Returns (current, max) or nil on failure.
    private func readSynchronous(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
#if arch(arm64)
        return arm64Read(displayID: displayID, command: command)
#else
        return intelReadSynchronous(displayID: displayID, command: command)
#endif
    }

    // MARK: - Intel Write/Read (renamed from original writeSynchronous/readSynchronous)

    private func intelWriteSynchronous(displayID: CGDirectDisplayID, command: UInt8, value: UInt16) -> Bool {
        guard let fb = framebufferService(for: displayID) else {
            #if DEBUG
            print("[DDCService] intelWrite: no framebuffer for display \(displayID)")
            #endif
            return false
        }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses (DDC bus is not always bus 0)
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            // Build DDC/CI Set VCP packet:
            // [0x51, 0x84, 0x03, VCP, val_hi, val_lo, checksum]
            var buf: [UInt8] = [
                0x51,
                0x84,
                0x03,
                command,
                UInt8(value >> 8),
                UInt8(value & 0xFF)
            ]
            buf.append(ddcChecksum(destAddress: 0x6E, bytes: buf))
            let bufCount = buf.count

            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ptr = raw.baseAddress else { return false }
                var req = IOI2CRequest()
                req.commFlags           = 0
                req.sendAddress         = 0x6E
                req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                req.sendSubAddress      = 0
                req.sendBuffer          = UInt(bitPattern: ptr)
                req.sendBytes           = UInt32(bufCount)
                req.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                req.replyBytes          = 0
                req.minReplyDelay       = 10_000_000 // 10ms
                let kr = IOI2CSendRequest(conn, IOOptionBits(0), &req)
                return kr == KERN_SUCCESS && req.result == KERN_SUCCESS
            }
            if ok {
                #if DEBUG
                print("[DDCService] Intel write VCP 0x\(String(command, radix:16)) = \(value) on bus \(busIndex) OK")
                #endif
                return true
            }
        }
        #if DEBUG
        print("[DDCService] intelWrite: all buses failed for display \(displayID) VCP 0x\(String(command, radix:16))")
        #endif
        return false
    }

    private func intelReadSynchronous(displayID: CGDirectDisplayID, command: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let fb = framebufferService(for: displayID) else { return nil }
        defer { IOObjectRelease(fb) }

        // Try all I2C buses
        for busIndex: UInt32 in 0..<8 {
            var iface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(fb, busIndex, &iface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iface) }

            var conn: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(iface, IOOptionBits(0), &conn) == KERN_SUCCESS,
                  let conn = conn else { continue }
            defer { IOI2CInterfaceClose(conn, IOOptionBits(0)) }

            // Build DDC/CI Get VCP request:
            // [0x51, 0x82, 0x01, VCP, checksum]
            var sendBuf: [UInt8] = [0x51, 0x82, 0x01, command]
            sendBuf.append(ddcChecksum(destAddress: 0x6E, bytes: sendBuf))

            var replyBuf = [UInt8](repeating: 0, count: 12)
            var result: (current: UInt16, max: UInt16)? = nil

            let sendCount  = sendBuf.count
            let replyCount = replyBuf.count

            sendBuf.withUnsafeMutableBytes { sendRaw in
                replyBuf.withUnsafeMutableBytes { replyRaw in
                    guard let sp = sendRaw.baseAddress,
                          let rp = replyRaw.baseAddress else { return }

                    var req = IOI2CRequest()
                    req.commFlags           = 0
                    req.sendAddress         = 0x6E
                    req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    req.sendSubAddress      = 0
                    req.sendBuffer          = UInt(bitPattern: sp)
                    req.sendBytes           = UInt32(sendCount)
                    req.replyAddress        = 0x6F
                    req.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                    req.replySubAddress     = 0
                    req.replyBuffer         = UInt(bitPattern: rp)
                    req.replyBytes          = UInt32(replyCount)
                    req.minReplyDelay       = 50_000_000 // 50ms

                    guard IOI2CSendRequest(conn, IOOptionBits(0), &req) == KERN_SUCCESS,
                          req.result == KERN_SUCCESS else { return }

                    // DDC/CI VCP reply layout:
                    // [0x6E, 0x88, 0x02, errCode, VCPcode, type, max_hi, max_lo, cur_hi, cur_lo, chk]
                    let rb = replyRaw.bindMemory(to: UInt8.self)
                    let maxVal = (UInt16(rb[6]) << 8) | UInt16(rb[7])
                    let curVal = (UInt16(rb[8]) << 8) | UInt16(rb[9])
                    result = (current: curVal, max: maxVal)
                }
            }
            if let r = result { return r }
        }
        return nil
    }

    // MARK: - Cache Cleanup

    /// Removes all cached VCP entries for a display that is no longer connected.
    func clearCache(for displayID: CGDirectDisplayID) {
        cacheLock.lock()
        vcpCache.removeValue(forKey: displayID)
        cacheLock.unlock()
#if arch(arm64)
        invalidateAVServiceCache(for: displayID)
#endif
    }

    // MARK: - Public Async API (with retry)

    /// Asynchronously write a VCP value, retrying up to 3 times.
    /// Invalidates the cache for the written VCP code on success.
    func writeAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        value: UInt16,
        completion: ((Bool) -> Void)? = nil
    ) {
        ddcQueue.async {
            for attempt in 0..<3 {
                if self.writeSynchronous(displayID: displayID, command: command, value: value) {
                    // Invalidate cached value so next read reflects the new setting.
                    self.cacheLock.lock()
                    self.vcpCache[displayID]?[command] = nil
                    self.cacheLock.unlock()
                    completion?(true)
                    return
                }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
            completion?(false)
        }
    }

    /// Asynchronously writes only the most recent requested value for a display/VCP pair.
    /// This keeps sliders and repeated brightness keys responsive by dropping stale
    /// intermediate DDC writes while one I2C transaction is already in flight.
    func writeLatestAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        value: UInt16,
        completion: ((Bool) -> Void)? = nil
    ) {
        let key = WriteKey(displayID: displayID, command: command)
        ddcQueue.async {
            self.latestWriteValues[key] = value
            if let completion {
                self.latestWriteCallbacks[key, default: []].append(completion)
            }
            guard !self.latestWriteActive.contains(key) else { return }
            self.latestWriteActive.insert(key)
            self.drainLatestWrite(for: key)
        }
    }

    private func drainLatestWrite(for key: WriteKey) {
        guard let value = latestWriteValues.removeValue(forKey: key) else {
            latestWriteActive.remove(key)
            return
        }

        let callbacks = latestWriteCallbacks.removeValue(forKey: key) ?? []
        let success: Bool
        if latestWriteLastValues[key] == value {
            success = true
        } else {
            success = writeSynchronous(displayID: key.displayID, command: key.command, value: value)
            if success {
                latestWriteLastValues[key] = value
                cacheLock.lock()
                vcpCache[key.displayID]?[key.command] = nil
                cacheLock.unlock()
            }
        }

        callbacks.forEach { $0(success) }

        if latestWriteValues[key] != nil {
            ddcQueue.async {
                self.drainLatestWrite(for: key)
            }
        } else {
            latestWriteActive.remove(key)
        }
    }

    /// Asynchronously read a VCP value.
    /// Returns a cached result if available and not expired (5-second TTL).
    func readAsync(
        displayID: CGDirectDisplayID,
        command: UInt8,
        completion: @escaping ((current: UInt16, max: UInt16)?) -> Void
    ) {
        // Fast path: return cached value if still fresh
        cacheLock.lock()
        if let entry = vcpCache[displayID]?[command], !entry.isExpired {
            cacheLock.unlock()
            completion((current: entry.current, max: entry.max))
            return
        }
        cacheLock.unlock()

        ddcQueue.async {
            for attempt in 0..<3 {
                if let r = self.readSynchronous(displayID: displayID, command: command) {
                    self.cacheLock.lock()
                    if self.vcpCache[displayID] == nil { self.vcpCache[displayID] = [:] }
                    self.vcpCache[displayID]![command] = VCPCacheEntry(
                        current: r.current, max: r.max, timestamp: Date()
                    )
                    self.cacheLock.unlock()
                    completion(r)
                    return
                }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
            completion(nil)
        }
    }

    /// Reads a batch of common VCP codes asynchronously.
    /// Every requested code appears in the result dictionary:
    ///   - `.some(value)` means the code was read successfully (or served from cache)
    ///   - `.none` means the I2C read was attempted but failed
    func readBatchVCPCodes(displayID: CGDirectDisplayID) async -> [UInt8: UInt16?] {
        let codes: [UInt8] = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x87, 0xD6, 0xDC]

        // Check if we have a full fresh cache for all codes
        let cachedResult: [UInt8: UInt16?]? = cacheLock.withLock {
            guard let existingCache = vcpCache[displayID] else { return nil }
            let allCached = codes.allSatisfy { existingCache[$0].map { !$0.isExpired } ?? false }
            guard allCached else { return nil }
            return Dictionary(uniqueKeysWithValues: codes.map { code -> (UInt8, UInt16?) in
                guard let entry = existingCache[code] else { return (code, nil) }
                return (code, entry.current)
            })
        }
        if let cachedResult {
            return cachedResult
        }

        return await withCheckedContinuation { continuation in
            ddcQueue.async {
                var result: [UInt8: UInt16?] = [:]
                var cachedCodes = Set<UInt8>()

                // Seed result with any still-valid cached values
                self.cacheLock.lock()
                if let cache = self.vcpCache[displayID] {
                    for code in codes {
                        if let entry = cache[code], !entry.isExpired {
                            result[code] = entry.current
                            cachedCodes.insert(code)
                        }
                    }
                }
                self.cacheLock.unlock()

                // For each code with no fresh cache entry, perform a real I2C read.
                // Every code ends up in result: success -> .some(value), failure -> .none.
                for code in codes {
                    if cachedCodes.contains(code) { continue }
                    if let r = self.readSynchronous(displayID: displayID, command: code) {
                        result[code] = r.current
                        self.cacheLock.lock()
                        if self.vcpCache[displayID] == nil { self.vcpCache[displayID] = [:] }
                        self.vcpCache[displayID]![code] = VCPCacheEntry(
                            current: r.current, max: r.max, timestamp: Date()
                        )
                        self.cacheLock.unlock()
                        // No extra delay here — arm64Read already waits 40ms per DDC/CI spec
                    } else {
                        result[code] = nil
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }
}
