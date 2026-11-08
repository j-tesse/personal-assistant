import Foundation

// A killed/crashed pa never closes its AVAudioFile → the RIFF + `data` sizes stay at their create-time values (0)
// → AVAudioFile rejects the file (`invalidAudioData`, seen on the Mac 2026-11-04) → whole recording lost.

public enum WavRepairResult: Equatable, Sendable {
    case consistent
    /// Header rewritten; `frames` = whole frames now in `data`, `droppedBytes` = trailing partial frame cut off.
    case repaired(frames: Int, droppedBytes: Int)
    /// Not a RIFF/WAVE file, no `fmt `/`data` chunk, or > 4 GB: left untouched so the decode error still surfaces.
    case notRepairable(String)
}

/// Sets the RIFF size and the `data` size from the file length (data rounded down to whole frames, partial frame
/// truncated). Walks every chunk: AVAudioFile Float32 writes `fmt ` (extensible) + `fact`/`FLLR` before `data`.
/// A consistent file (incl. chunks after `data`) is never written to.
@discardableResult
public func repairWavHeader(_ url: URL) throws -> WavRepairResult {
    let h = try FileHandle(forUpdating: url)
    defer { try? h.close() }
    let fileLen = try h.seekToEnd()
    func read(_ at: UInt64, _ n: Int) throws -> [UInt8] {
        try h.seek(toOffset: at)
        return [UInt8](try h.read(upToCount: n) ?? Data())
    }
    func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]) }

    func chunkChainEnds(at start: UInt64) throws -> Bool {
        var p = start
        while p + 8 <= fileLen {
            let ch = try read(p, 8)
            guard ch[0..<4].allSatisfy({ (0x20...0x7e).contains($0) }) else { return false }
            let s = UInt64(u32(ch, 4))
            p += 8 + s + s % 2
            if p == fileLen + 1 && s % 2 == 1 { return true }  // pad byte missing at EOF
        }
        return p == fileLen
    }

    let head = try read(0, 12)
    guard head.count == 12, head[0..<4] == [0x52, 0x49, 0x46, 0x46], head[8..<12] == [0x57, 0x41, 0x56, 0x45] else {
        return .notRepairable("not a RIFF/WAVE file")
    }
    guard fileLen - 8 <= UInt64(UInt32.max) else { return .notRepairable("larger than 4 GB") }
    var blockAlign: UInt64?
    var pos: UInt64 = 12
    while pos + 8 <= fileLen {
        let ch = try read(pos, 8)
        let id = String(decoding: ch[0..<4], as: UTF8.self)
        let size = UInt64(u32(ch, 4))
        let body = pos + 8
        if id == "fmt " {
            let fmt = try read(body, 16)
            guard size >= 16, fmt.count == 16 else { return .notRepairable("short fmt chunk") }
            blockAlign = UInt64(fmt[12]) | UInt64(fmt[13]) << 8
        } else if id == "data" {
            guard let align = blockAlign, align > 0 else { return .notRepairable("data before a valid fmt chunk") }
            let available = fileLen - body
            // Declared size is real iff what follows it is a chunk chain ending at EOF (finalized file, maybe with
            // LIST etc. after data). A stale size (0 before close) is followed by raw samples instead.
            let trusted = try size <= available && size % align == 0 && chunkChainEnds(at: body + size + size % 2)
            let dataLen = trusted ? size : available / align * align
            let newLen = trusted ? fileLen : body + dataLen
            if trusted && u32(head, 4) == UInt32(fileLen - 8) { return .consistent }
            if newLen < fileLen { try h.truncate(atOffset: newLen) }
            try h.seek(toOffset: 4)
            try h.write(contentsOf: le32(UInt32(newLen - 8)))
            try h.seek(toOffset: pos + 4)
            try h.write(contentsOf: le32(UInt32(dataLen)))
            try h.synchronize()
            return .repaired(frames: Int(dataLen / align), droppedBytes: Int(fileLen - newLen))
        }
        pos = body + size + size % 2
    }
    return .notRepairable("no data chunk")
}
