import Foundation
import Testing
@testable import Trio

@Suite("Log shipper") struct LogShipperTests {
    // MARK: - Temp log files

    private struct Logs {
        let current: URL
        let previous: URL
        private let fileManager = FileManager.default

        init() {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogShipperTests-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            current = dir.appendingPathComponent("log.txt")
            previous = dir.appendingPathComponent("log_prev.txt")
        }

        var reader: LogTailReader { LogTailReader(currentURL: current, previousURL: previous) }

        func create(_ text: String, created: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            fileManager.createFile(atPath: current.path, contents: text.data(using: .utf8), attributes: [.creationDate: created])
        }

        func append(_ text: String) {
            let handle = try! FileHandle(forWritingTo: current)
            try! handle.seekToEnd()
            try! handle.write(contentsOf: text.data(using: .utf8)!)
            try! handle.close()
        }

        /// What SimpleLogReporter / DanaLogWriter do on the first write of a new day.
        func rotate(newContent: String, created: Date = Date(timeIntervalSince1970: 1_700_086_400)) {
            try? fileManager.removeItem(at: previous)
            try! fileManager.moveItem(at: current, to: previous)
            create(newContent, created: created)
        }

        func truncate(to text: String) {
            let handle = try! FileHandle(forWritingTo: current)
            try! handle.truncate(atOffset: 0)
            try! handle.write(contentsOf: text.data(using: .utf8)!)
            try! handle.close()
        }
    }

    private func text(_ batch: LogTailReader.Batch?) -> String? {
        batch.map { String(decoding: $0.data, as: UTF8.self) }
    }

    // MARK: - LogTailReader

    @Test("First run ships from the start of the current file") func firstRun() {
        let logs = Logs()
        logs.create("a\nb\n")
        let id = LogTailReader.info(of: logs.current)!.id

        let first = logs.reader.next(state: LogTailReader.StreamState(), limit: 1 << 20)
        #expect(text(first.batch) == "a\nb\n")
        #expect(first.batch?.from == 0)
        #expect(first.batch?.to == 4)
        #expect(first.batch?.gapBefore == false)
        #expect(first.batch?.fileId == id)
        #expect(first.stateAfterSuccess == LogTailReader.StreamState(fileId: id, offset: 4))

        let second = logs.reader.next(state: first.stateAfterSuccess, limit: 1 << 20)
        #expect(second.batch == nil)
        #expect(second.stateAfterSuccess == first.stateAfterSuccess)
    }

    @Test("A line without its newline waits") func partialLine() {
        let logs = Logs()
        logs.create("a\nbc")
        let first = logs.reader.next(state: LogTailReader.StreamState(), limit: 1 << 20)
        #expect(text(first.batch) == "a\n")
        #expect(first.batch?.to == 2)

        let waiting = logs.reader.next(state: first.stateAfterSuccess, limit: 1 << 20)
        #expect(waiting.batch == nil)

        logs.append("\n")
        let rest = logs.reader.next(state: first.stateAfterSuccess, limit: 1 << 20)
        #expect(text(rest.batch) == "bc\n")
        #expect(rest.batch?.from == 2)
        #expect(rest.batch?.to == 5)
    }

    @Test("The limit cuts at the last newline") func limitCutsAtNewline() {
        let logs = Logs()
        logs.create("aaaa\nbbbb\ncccc\n")
        let first = logs.reader.next(state: LogTailReader.StreamState(), limit: 7)
        #expect(text(first.batch) == "aaaa\n")
        let second = logs.reader.next(state: first.stateAfterSuccess, limit: 7)
        #expect(text(second.batch) == "bbbb\n")
        #expect(second.batch?.from == 5)
    }

    @Test("A line longer than the limit ships in pieces") func longLine() {
        let logs = Logs()
        logs.create("aaaaaaaaaa\n")
        let first = logs.reader.next(state: LogTailReader.StreamState(), limit: 4)
        #expect(text(first.batch) == "aaaa")
        let second = logs.reader.next(state: first.stateAfterSuccess, limit: 4)
        #expect(text(second.batch) == "aaaa")
        let third = logs.reader.next(state: second.stateAfterSuccess, limit: 4)
        #expect(text(third.batch) == "aa\n")
        #expect(third.batch?.to == 11)
    }

    @Test("A long line is never cut inside a UTF-8 sequence") func longLineUTF8() {
        let logs = Logs()
        logs.create("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") // 79 bytes
        logs.append("ė" + "b" + "\n") // "ė" = 0xC4 0x97 at bytes 79-80
        let first = logs.reader.next(state: LogTailReader.StreamState(), limit: 80) // byte 80 would split "ė"
        #expect(first.batch?.to == 79)
        #expect(text(first.batch)?.contains("\u{FFFD}") == false)
        let second = logs.reader.next(state: first.stateAfterSuccess, limit: 80)
        #expect(text(second.batch) == "ėb\n")
        #expect(second.batch?.to == 83)
    }

    @Test("After a rotation the previous file is finished first") func rotation() {
        let logs = Logs()
        logs.create("day1-a\n")
        let id1 = LogTailReader.info(of: logs.current)!.id
        let shipped = logs.reader.next(state: LogTailReader.StreamState(), limit: 1 << 20)
        #expect(shipped.batch?.to == 7)

        logs.append("day1-b\n")
        logs.rotate(newContent: "day2-a\n")
        let id2 = LogTailReader.info(of: logs.current)!.id
        #expect(id1 != id2)

        let rest = logs.reader.next(state: shipped.stateAfterSuccess, limit: 1 << 20)
        #expect(rest.batch?.fileId == id1)
        #expect(text(rest.batch) == "day1-b\n")
        #expect(rest.batch?.from == 7)
        #expect(rest.batch?.gapBefore == false)
        #expect(rest.stateAfterSuccess == LogTailReader.StreamState(fileId: id1, offset: 14))

        let fresh = logs.reader.next(state: rest.stateAfterSuccess, limit: 1 << 20)
        #expect(fresh.batch?.fileId == id2)
        #expect(text(fresh.batch) == "day2-a\n")
        #expect(fresh.batch?.from == 0)
        #expect(fresh.batch?.gapBefore == false)
    }

    @Test("A rotated file ending without a newline is shipped to its end") func rotatedFileWithoutNewline() {
        let logs = Logs()
        logs.create("day1-a\n")
        let shipped = logs.reader.next(state: LogTailReader.StreamState(), limit: 1 << 20)
        logs.append("day1-partial") // app killed mid-write, then the day rolled over
        logs.rotate(newContent: "day2-a\n")
        let id2 = LogTailReader.info(of: logs.current)!.id

        let rest = logs.reader.next(state: shipped.stateAfterSuccess, limit: 1 << 20)
        #expect(text(rest.batch) == "day1-partial")
        #expect(rest.batch?.to == 19)

        let fresh = logs.reader.next(state: rest.stateAfterSuccess, limit: 1 << 20)
        #expect(fresh.batch?.fileId == id2)
        #expect(text(fresh.batch) == "day2-a\n")
    }

    @Test("Two missed rotations: the previous day is shipped first, flagged as a gap") func twoMissedRotations() {
        let logs = Logs()
        logs.create("fri\n")
        let shipped = logs.reader.next(state: LogTailReader.StreamState(), limit: 1 << 20)
        logs.rotate(newContent: "sat\n", created: Date(timeIntervalSince1970: 1_700_086_400))
        let idSat = LogTailReader.info(of: logs.current)!.id
        logs.rotate(newContent: "sun\n", created: Date(timeIntervalSince1970: 1_700_172_800))
        let idSun = LogTailReader.info(of: logs.current)!.id

        let saturday = logs.reader.next(state: shipped.stateAfterSuccess, limit: 1 << 20)
        #expect(saturday.batch?.fileId == idSat)
        #expect(text(saturday.batch) == "sat\n")
        #expect(saturday.batch?.gapBefore == true)

        let sunday = logs.reader.next(state: saturday.stateAfterSuccess, limit: 1 << 20)
        #expect(sunday.batch?.fileId == idSun)
        #expect(text(sunday.batch) == "sun\n")
        #expect(sunday.batch?.gapBefore == false)
    }

    @Test("pump_error throttle key ignores numbers") func throttleKey() {
        #expect(
            TrioEventNote.throttleKey(forPumpError: "Pump Error (timeout after 12 s, attempt 3)") ==
                TrioEventNote.throttleKey(forPumpError: "Pump Error (timeout after 7 s, attempt 4)")
        )
        #expect(TrioEventNote.throttleKey(forPumpError: "a") != TrioEventNote.throttleKey(forPumpError: "b"))
    }

    @Test("A missed rotation is a gap") func missedRotation() {
        let logs = Logs()
        logs.create("x\n")
        let id = LogTailReader.info(of: logs.current)!.id
        let result = logs.reader.next(state: LogTailReader.StreamState(fileId: "999:1", offset: 10), limit: 1 << 20)
        #expect(result.batch?.fileId == id)
        #expect(result.batch?.from == 0)
        #expect(result.batch?.gapBefore == true)
        #expect(text(result.batch) == "x\n")
    }

    @Test("A truncated file is a gap") func truncation() {
        let logs = Logs()
        logs.create("abcdef\n")
        let shipped = logs.reader.next(state: LogTailReader.StreamState(), limit: 1 << 20)
        #expect(shipped.batch?.to == 7)

        logs.truncate(to: "z\n")
        let result = logs.reader.next(state: shipped.stateAfterSuccess, limit: 1 << 20)
        #expect(result.batch?.from == 0)
        #expect(result.batch?.gapBefore == true)
        #expect(text(result.batch) == "z\n")
    }

    @Test("A gap found on an empty file is carried to the next batch") func gapSurvivesEmptyFile() throws {
        let logs = Logs()
        logs.create("")
        let waiting = logs.reader.next(state: LogTailReader.StreamState(fileId: "999:1", offset: 10), limit: 1 << 20)
        #expect(waiting.batch == nil)
        #expect(waiting.stateAfterSuccess.gapPending == true)
        #expect(waiting.stateAfterSuccess.offset == 0)

        // The state round-trips through JSON (UserDefaults).
        let encoded = try JSONEncoder().encode(waiting.stateAfterSuccess)
        let decoded = try JSONDecoder().decode(LogTailReader.StreamState.self, from: encoded)
        #expect(decoded == waiting.stateAfterSuccess)

        logs.append("x\n")
        let shipped = logs.reader.next(state: decoded, limit: 1 << 20)
        #expect(shipped.batch?.gapBefore == true)
        #expect(shipped.batch?.from == 0)
        #expect(shipped.stateAfterSuccess.gapPending == false)
    }

    @Test("No log file yet: nothing to ship, state untouched") func missingFile() {
        let logs = Logs()
        let state = LogTailReader.StreamState(fileId: "1:2", offset: 3)
        let result = logs.reader.next(state: state, limit: 1 << 20)
        #expect(result.batch == nil)
        #expect(result.stateAfterSuccess == state)
    }

    // MARK: - LogRedactor

    @Test("Dana pairing key is redacted") func redactPairingKey() {
        let line = "[2026-11-01T10:00:00+0200 INFO] PeripheralManager.swift - processPairingRequest2(_:)#456: processPairingRequest2 -> pairingKey: a1b2"
        let out = LogRedactor.redact(line)
        #expect(out.contains("pairingKey: [redacted]"))
        #expect(!out.contains("a1b2"))
    }

    @Test("Dana keys in every DanaKit form are redacted, packets around them too") func redactDanaKeyForms() {
        let chunk = """
        [..] PeripheralManager.swift - peripheral(_:didUpdateValueFor:error:)#297: Receiving data: a1b2c3d4
        [..] PeripheralManager.swift - sendV3PairingInformationEmpty()#370: Setting encryption keys. Pairing key: 0a0b0c0d0e0f, random pairing key: 1a1b1c, random sync key: 17
        [..] PeripheralManager.swift - writeMessage(_:)#94: Sending data - Name: General_KeepConnection, OpCode: 255, Encoded data: ffee
        [..] PeripheralManager.swift - finishV3Pairing()#425: Storing security keys: Pairing key: 0a0b0c0d0e0f, random pairing key: 1a1b1c
        [..] PeripheralManager.swift - parseReceivedValue(_:)#650: Received message! Starting to decrypt data: 9988
        """
        let out = LogRedactor.redact(chunk)
        for secret in ["0a0b0c0d0e0f", "1a1b1c", "sync key: 17", "a1b2c3d4", "ffee", "9988"] {
            #expect(!out.contains(secret), "\(secret) leaked")
        }
        #expect(out.contains("Pairing key: [redacted], random pairing key: [redacted], random sync key: [redacted]"))
        #expect(out.contains("Receiving data: [redacted:pairing]"))
        #expect(out.contains("Encoded data: [redacted:pairing]"))
        #expect(out.contains("decrypt data: [redacted:pairing]"))

        // The per-connect "Setting encryption keys" line redacts its keys but opens no window:
        // the packets around it stay (they are the diagnostics the stream exists for).
        let connect = """
        [..] PeripheralManager.swift - peripheral(_:didUpdateValueFor:error:)#297: Receiving data: a1b2c3d4
        [..] PeripheralManager.swift - sendV3PairingInformationEmpty()#370: Setting encryption keys. Pairing key: 0a0b0c0d0e0f, random pairing key: 1a1b1c, random sync key: 17
        [..] PeripheralManager.swift - parseReceivedValue(_:)#658: Decoding successful! Data: ffee
        """
        let kept = LogRedactor.redact(connect)
        #expect(kept.contains("Pairing key: [redacted], random pairing key: [redacted], random sync key: [redacted]"))
        #expect(kept.contains("Receiving data: a1b2c3d4"))
        #expect(kept.contains("Decoding successful! Data: ffee"))
    }

    @Test("APNS device token is redacted") func redactDeviceToken() {
        let out = LogRedactor.redact("... - DEV: Device token updated: 0123abcd4567")
        #expect(out.hasSuffix("Device token updated: [redacted]"))
    }

    @Test("Query-string secrets and bearer tokens are redacted") func redactQuery() {
        let out = LogRedactor.redact("GET https://ns.example.com/api/v1/entries.json?count=10&token=abc123&x=1 Authorization: Bearer abcdefghijkl")
        #expect(out.contains("count=10&token=[redacted]&x=1"))
        #expect(out.contains("Bearer [redacted]"))
        #expect(!out.contains("abc123"))
        #expect(!out.contains("abcdefghijkl"))
    }

    @Test("During a pairing every packet is redacted") func redactPairingMode() {
        let chunk = """
        [..] PeripheralManager.swift - sendPairingRequest()#384: Sending pairing request. Data: 0a0b0c
        [..] PeripheralManager.swift - parseReceivedValue(_:)#658: Decoding successful! Data: ffee
        """
        let out = LogRedactor.redact(chunk)
        #expect(out.contains("Sending pairing request. Data: [redacted]"))
        #expect(out.contains("Decoding successful! Data: [redacted:pairing]"))
        #expect(LogRedactor.redact("Decoding successful! Data: ffee") == "Decoding successful! Data: ffee") // no marker → kept
        #expect(!out.contains("0a0b0c"))
        #expect(!out.contains("ffee"))
    }

    @Test("Pairing redaction is a window, not the whole batch") func redactPairingWindow() {
        let packet = "[..] PeripheralManager.swift - parseReceivedValue(_:)#658: Decoding successful! Data: ffee"
        let marker = "[..] PeripheralManager.swift - sendPairingRequest()#384: Sending pairing request. Data: 0a0b0c"
        var lines = [String](repeating: packet, count: 400)
        lines[200] = marker
        let out = LogRedactor.redact(lines.joined(separator: "\n")).components(separatedBy: "\n")
        #expect(out[200].hasSuffix("Data: [redacted]"))
        #expect(out[200 - LogRedactor.pairingLinesBefore].hasSuffix(LogRedactor.redactedPairing))
        #expect(out[200 - LogRedactor.pairingLinesBefore - 1] == packet)
        #expect(out[200 + LogRedactor.pairingLinesAfter].hasSuffix(LogRedactor.redactedPairing))
        #expect(out[200 + LogRedactor.pairingLinesAfter + 1] == packet)
        #expect(out[0] == packet)
        #expect(out[399] == packet)
    }

    @Test("Ordinary lines are untouched") func redactLeavesOrdinaryLines() {
        let lines = [
            "[..] PeripheralManager.swift - parseReceivedValue(_:)#658: Decoding successful! Data: ffee",
            "[..] BluetoothManager.swift - didDisconnectPeripheral#251: Device disconnected, name: YID00023FI",
            "2026-11-01T00:02:20+0200 [Nightscout] FetchGlucoseManager.swift - DEV: ⚫️⚫️⚫️ Glucose fetched, count=12"
        ].joined(separator: "\n")
        #expect(LogRedactor.redact(lines) == lines)
    }

    // MARK: - TrioEventNote

    @Test("bolus_deleted") func noteBolusDeleted() {
        let event = TrioEvent.bolusDeleted(
            id: "6F2B", amount: Decimal(string: "0.15")!, kind: .smb, delivered: true,
            at: Date(timeIntervalSince1970: 1_793_607_153)
        )
        #expect(TrioEventNote.format(event) == "[trio-event v1] bolus_deleted id=6F2B amount=0.15 kind=smb delivered=true at=2026-11-02T08:12:33Z")
    }

    @Test("bolus_deleted without delivered (external insulin)") func noteBolusDeletedExternal() {
        let event = TrioEvent.bolusDeleted(
            id: "x", amount: 2, kind: .external, delivered: nil, at: Date(timeIntervalSince1970: 0)
        )
        #expect(TrioEventNote.format(event) == "[trio-event v1] bolus_deleted id=x amount=2 kind=external at=1970-01-01T00:00:00Z")
    }

    @Test("bolus_failed and pump_error sanitize the error text") func noteErrors() {
        #expect(TrioEventNote.format(.bolusFailed(error: nil)) == "[trio-event v1] bolus_failed kind=manual")
        #expect(
            TrioEventNote.format(.bolusFailed(error: "Pump Error (\"timeout\")\n  second line")) ==
                "[trio-event v1] bolus_failed kind=manual err=\"Pump Error ('timeout') second line\""
        )
        let long = String(repeating: "x", count: 200)
        let note = TrioEventNote.format(.pumpError(error: long))
        let err = note.components(separatedBy: "err=\"")[1].dropLast()
        #expect(err.count == TrioEventNote.maxErrorLength)
        #expect(err.hasSuffix("…"))
    }

    @Test("Throttle: one per key per window") func throttle() {
        var throttle = EventThrottle(window: 30 * 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = throttle.allow("a", at: t0)
        let repeated = throttle.allow("a", at: t0.addingTimeInterval(10 * 60))
        let other = throttle.allow("b", at: t0.addingTimeInterval(10 * 60))
        let later = throttle.allow("a", at: t0.addingTimeInterval(31 * 60))
        #expect(first)
        #expect(!repeated)
        #expect(other)
        #expect(later)
        // Entries older than the window are evicted, so the table cannot grow without bound:
        // at +31 min "a" (t0) was evicted and re-added, "b" (+10 min) is still inside the window.
        #expect(throttle.count == 2)
        _ = throttle.allow("c", at: t0.addingTimeInterval(41 * 60)) // "b" is now 31 min old → gone
        #expect(throttle.count == 2)
    }

    // MARK: - Wire format

    @Test("Payload encodes to raw DEFLATE JSON with the spec's keys") func codecRoundTrip() throws {
        let payload = LogShipmentPayload(
            installId: "0a1b",
            app: LogShipmentPayload.App(version: "1.0.1", build: "2", sha: "3943384b8"),
            sentAt: "2026-11-02T08:15:00Z",
            batches: [LogShipmentPayload.Batch(stream: "trio", fileId: "12:1761948000", from: 10, to: 20, gapBefore: true, text: "a\n")]
        )
        let body = try LogShipmentCodec.encode(payload)
        let json = try JSONSerialization.jsonObject(with: LogShipmentCodec.decode(body)) as! [String: Any]
        #expect(json["v"] as? Int == 1)
        #expect(json["install_id"] as? String == "0a1b")
        #expect(json["sent_at"] as? String == "2026-11-02T08:15:00Z")
        #expect((json["app"] as? [String: String])?["sha"] == "3943384b8")
        let batch = (json["batches"] as? [[String: Any]])?.first
        #expect(batch?["stream"] as? String == "trio")
        #expect(batch?["file_id"] as? String == "12:1761948000")
        #expect(batch?["from"] as? Int == 10)
        #expect(batch?["to"] as? Int == 20)
        #expect(batch?["gap_before"] as? Bool == true)
        #expect(batch?["text"] as? String == "a\n")
    }

    @Test("Responses map to outcomes") func responses() {
        let accepted = #"{"accepted":[{"stream":"trio","file_id":"1:2","to":40}]}"#.data(using: .utf8)!
        #expect(
            LogShipperResponse.parse(status: 200, retryAfter: nil, body: accepted) ==
                .accepted([LogShipmentAccepted(stream: "trio", fileId: "1:2", to: 40)])
        )
        #expect(LogShipperResponse.parse(status: 200, retryAfter: nil, body: Data("nope".utf8)) == .retryLater(after: nil, message: "HTTP 200: unreadable response"))
        #expect(LogShipperResponse.parse(status: 401, retryAfter: nil, body: Data()) == .unauthorized)
        #expect(LogShipperResponse.parse(status: 403, retryAfter: nil, body: Data()) == .unauthorized)
        #expect(LogShipperResponse.parse(status: 413, retryAfter: nil, body: Data()) == .tooLarge)
        #expect(LogShipperResponse.parse(status: 429, retryAfter: "120", body: Data()) == .retryLater(after: 120, message: "HTTP 429"))
        #expect(LogShipperResponse.parse(status: 503, retryAfter: "99999", body: Data()) == .retryLater(after: 3600, message: "HTTP 503"))
        #expect(LogShipperResponse.parse(status: 500, retryAfter: nil, body: Data()) == .retryLater(after: nil, message: "HTTP 500"))
    }

    @Test("A partial accept continues from the end of the last complete line") func partialAccept() {
        // bytes: a b \n c d ė(2) \n f g \n  → 11 bytes, offsets 100…111
        let batch = LogTailReader.Batch(fileId: "1:2", from: 100, to: 111, gapBefore: false, data: Data("ab\ncdė\nfg\n".utf8))
        #expect(batch.lineAlignedOffset(upTo: 111) == 111)
        #expect(batch.lineAlignedOffset(upTo: 500) == 111)
        #expect(batch.lineAlignedOffset(upTo: 106) == 103) // inside "cdė" → back to after "ab\n"
        #expect(batch.lineAlignedOffset(upTo: 108) == 108) // exactly after "cdė\n"
        #expect(batch.lineAlignedOffset(upTo: 102) == nil) // not even one line
        #expect(batch.lineAlignedOffset(upTo: 100) == nil)
        // A fragment of an over-long line (no newline at all) may continue from any accepted byte.
        let fragment = LogTailReader.Batch(fileId: "1:2", from: 100, to: 104, gapBefore: false, data: Data("abcd".utf8))
        #expect(fragment.lineAlignedOffset(upTo: 102) == 102)
        #expect(LogShipperResponse.retryAfterInterval("nan") == nil)
        #expect(LogShipperResponse.retryAfterInterval("inf") == nil)
    }

    @Test("Retry-After as seconds or HTTP date") func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_793_607_153) // 2026-11-02T08:12:33Z
        #expect(LogShipperResponse.retryAfterInterval("120", now: now) == 120)
        #expect(LogShipperResponse.retryAfterInterval("Mon, 02 Nov 2026 08:22:33 GMT", now: now) == 600)
        #expect(LogShipperResponse.retryAfterInterval("Mon, 02 Nov 2026 08:00:00 GMT", now: now) == 0)
        #expect(LogShipperResponse.retryAfterInterval("Tue, 03 Nov 2026 08:00:00 GMT", now: now) == 3600)
        #expect(LogShipperResponse.retryAfterInterval("soon", now: now) == nil)
        #expect(LogShipperResponse.retryAfterInterval(nil, now: now) == nil)
    }

    @Test("Backoff doubles from 5 min to 60 min") func backoff() {
        #expect(BackoffPolicy.next(after: nil) == 300)
        #expect(BackoffPolicy.next(after: 300) == 600)
        #expect(BackoffPolicy.next(after: 2400) == 3600)
        #expect(BackoffPolicy.next(after: 3600) == 3600)
    }
}
