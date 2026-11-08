import Foundation
import Testing
@testable import PACore

private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)] }
private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
private func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
    Array(id.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? [0] : [])
}

/// Layout like AVAudioFile's 16 kHz mono Float32: `fmt ` extensible + `fact` + `FLLR` padding, then `data`.
/// riff/data nil = correct sizes; 0 = what an unclosed AVAudioFile leaves.
private func wav(frames: Int, extra: Int = 0, riff: UInt32? = nil, data: UInt32? = nil, after: [UInt8] = []) -> [UInt8] {
    let guid: [UInt8] = [0x03, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]
    let fields: [[UInt8]] = [le16(0xfffe), le16(1), le32(16000), le32(64000), le16(4), le16(32), le16(22), le16(32), le32(4), guid]
    let fmt: [UInt8] = fields.flatMap { $0 }
    let samples: [UInt8] = (0..<(frames * 4 + extra)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
    let fill = [UInt8](repeating: 0, count: 3932)
    let parts: [[UInt8]] = [
        Array("WAVE".utf8), chunk("fmt ", fmt), chunk("fact", le32(UInt32(frames))), chunk("FLLR", fill),
        Array("data".utf8), le32(data ?? UInt32(samples.count)), samples, after,
    ]
    let body: [UInt8] = parts.flatMap { $0 }
    return Array("RIFF".utf8) + le32(riff ?? UInt32(body.count)) + body
}

private func dataOffset(_ b: [UInt8]) -> Int {
    (0..<(b.count - 4)).first { b[$0..<($0 + 4)] == ArraySlice("data".utf8) }!
}
private func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

private func tempFile(_ bytes: [UInt8]) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("pa-wav-\(UUID().uuidString).wav")
    try Data(bytes).write(to: u)
    return u
}
private func bytes(_ u: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: u)) }

@Suite struct WavRepairTests {
    @Test func validFileUntouched() throws {
        let good = wav(frames: 100)
        let u = try tempFile(good)
        #expect(try repairWavHeader(u) == .consistent)
        #expect(try bytes(u) == good)
    }

    @Test func validFileWithChunkAfterDataUntouched() throws {
        let good = wav(frames: 100, after: chunk("LIST", Array("INFOISFT".utf8) + [1, 2, 3]))
        let u = try tempFile(good)
        #expect(try repairWavHeader(u) == .consistent)
        #expect(try bytes(u) == good)
    }

    @Test func zeroSizesFromUnclosedFileRepaired() throws {
        let good = wav(frames: 500)
        let u = try tempFile(wav(frames: 500, riff: 0, data: 0))
        #expect(try repairWavHeader(u) == .repaired(frames: 500, droppedBytes: 0))
        #expect(try bytes(u) == good)
        #expect(try repairWavHeader(u) == .consistent)
    }

    @Test func trailingPartialFrameDropped() throws {
        let u = try tempFile(wav(frames: 10, extra: 3, riff: 0, data: 0))
        #expect(try repairWavHeader(u) == .repaired(frames: 10, droppedBytes: 3))
        #expect(try bytes(u) == wav(frames: 10))
    }

    @Test func staleNonZeroDataSizeExtendedToEnd() throws {
        // Header updated mid-recording, then killed: samples follow the declared end, not a chunk.
        let u = try tempFile(wav(frames: 300, riff: 1000, data: 400))
        #expect(try repairWavHeader(u) == .repaired(frames: 300, droppedBytes: 0))
        #expect(try bytes(u) == wav(frames: 300))
    }

    @Test func onlyRiffSizeWrongKeepsTrailingChunk() throws {
        let list = chunk("LIST", Array("INFO".utf8))
        let u = try tempFile(wav(frames: 50, riff: 0, after: list))
        #expect(try repairWavHeader(u) == .repaired(frames: 50, droppedBytes: 0))
        #expect(try bytes(u) == wav(frames: 50, after: list))
    }

    @Test func notWavLeftAlone() throws {
        for junk in [Array("hello, not audio at all".utf8), [], Array("RIFF\0\0\0\0WAVEfmt ".utf8)] {
            let u = try tempFile(junk)
            guard case .notRepairable = try repairWavHeader(u) else { Issue.record("repaired \(junk)"); continue }
            #expect(try bytes(u) == junk)
        }
    }

    @Test func headerWithoutDataChunkLeftAlone() throws {
        // Killed between creating the file and writing `data`.
        let full = wav(frames: 0, riff: 0, data: 0)
        let cut = Array(full[0..<dataOffset(full)])
        let u = try tempFile(cut)
        #expect(try repairWavHeader(u) == .notRepairable("no data chunk"))
        #expect(try bytes(u) == cut)
    }
}

private let t0 = Date(timeIntervalSince1970: 1_790_589_600)
private let rid = "00000000-0000-4000-8000-000000000001"

private func tempStore() throws -> RecordingStore {
    let s = RecordingStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("pa-rec-\(UUID().uuidString)", isDirectory: true))
    try FileManager.default.createDirectory(at: s.dir, withIntermediateDirectories: true)
    return s
}

@Suite struct RecordingRepairTests {
    @Test func recoverInterruptedRepairsBothStreamsKeepsEnd() throws {
        let store = try tempStore()
        try store.save(RecordingMeta(id: rid, startedAt: t0))
        try Data(wav(frames: 40, extra: 2, riff: 0, data: 0)).write(to: store.micURL(rid))
        try Data(wav(frames: 60, riff: 0, data: 0)).write(to: store.systemURL(rid))
        for u in [store.micURL(rid), store.systemURL(rid)] {
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(300)], ofItemAtPath: u.path)
        }
        var logs: [String] = []
        let fixed = try store.recoverInterrupted { logs.append($0) }
        #expect(fixed.first?.endedAt == t0.addingTimeInterval(300))
        #expect(try bytes(store.micURL(rid)) == wav(frames: 40))
        #expect(try bytes(store.systemURL(rid)) == wav(frames: 60))
        #expect(logs.count == 2)
        #expect(logs[0].contains("repaired WAV header of \(rid)-mic.wav (40 frames, 2 trailing bytes dropped)"))
    }

    @Test func processorRepairsBeforeTranscribing() async throws {
        // Parked before the fix existed → `pa queue --retry` → repaired on the next attempt.
        let store = try tempStore()
        try store.save(RecordingMeta(id: rid, startedAt: t0, endedAt: t0.addingTimeInterval(60), attempts: 3, lastError: "invalidAudioData"))
        try Data(wav(frames: 80, riff: 0, data: 0)).write(to: store.micURL(rid))
        #expect(try store.retry("00000000").attempts == 0)
        let m = try #require(try store.all().items.first)
        #expect(m.lastError == nil)
        let p = RecordingProcessor(
            store: store,
            transcribe: { mic, _ in
                let b = try bytes(mic!)
                #expect(u32(b, dataOffset(b) + 4) == 320)
                return Transcription(segments: [], asrModel: "asr", diarizationModel: nil, warnings: [])
            },
            enqueue: { _ in }, keepAudioDays: { nil }, log: { _ in }, now: { t0 })
        #expect(try p.ready().map(\.id) == [rid])
        await p.process(m)
        #expect(store.audio(rid).mic == nil)  // transcribed → cleaned up (not failed)
    }

    @Test func retryRejectsUnknownAmbiguousAndLive() throws {
        let store = try tempStore()
        try store.save(RecordingMeta(id: rid, startedAt: t0, endedAt: t0, attempts: 3))
        try store.save(RecordingMeta(id: "00000000-0000-4000-8000-000000000002", startedAt: t0))
        #expect(throws: RecordingError("no recording abc")) { try store.retry("abc") }
        #expect(throws: RecordingError("00000000 matches 2 recordings")) { try store.retry("00000000") }
        #expect(throws: RecordingError.self) { try store.retry("00000000-0000-4000-8000-000000000002") }
        #expect(throws: RecordingError.self) { try store.retry("") }
        #expect(try store.retry(rid.uppercased()).id == rid)
    }
}
