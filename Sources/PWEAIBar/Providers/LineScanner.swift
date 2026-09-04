import Foundation

/// Finds the JSON lines worth decoding in a large append-only log.
///
/// Every provider here reads JSONL files that run to tens of megabytes, and in all of them the
/// lines we want are a small fraction of the total. The obvious approach — read as `String`,
/// `split` on newlines, test each line with `contains` — spends nearly all of its time in
/// Unicode-correct comparison while *rejecting* lines. Scanning raw bytes for an ASCII marker
/// and decoding only the survivors turned a several-second sweep into a fraction of one.
///
/// Read in fixed chunks rather than memory-mapped. Mapping was simpler and cost 84 MB resident:
/// touching every page of a 159 MB tree during the first sweep pulls all of it in, and a
/// menu-bar app that sits there all day does not get to hold that. Chunking caps the cost at
/// the buffer size no matter how large the logs grow.
enum LineScanner {

    /// 1 MB. Large enough that syscall overhead disappears, small enough to stay invisible.
    private static let chunkSize = 1 << 20

    /// A single line longer than this is skipped. Transcript lines carrying big tool results
    /// can reach megabytes; none of those are the assistant turns we are looking for, and
    /// accumulating one would defeat the point of chunking.
    private static let maxLine = 8 << 20

    /// Calls `body` for each line containing `marker`, in file order.
    /// Returns the offset just past the last **complete** line — a log being appended to can end
    /// mid-line, and resuming from inside one would produce garbage on the next pass.
    @discardableResult
    static func scan(_ url: URL, marker: String, from offset: Int = 0,
                     minLength: Int = 40, body: (Data) -> Void) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        if offset > 0, (try? handle.seek(toOffset: UInt64(offset))) == nil { return 0 }

        let needle = Array(marker.utf8)
        var consumed = offset       // offset just past the last complete line
        var overlong = false        // currently skipping a line past `maxLine`

        // One buffer, appended to and trimmed in place. `carry + chunk` allocated a fresh
        // buffer per chunk, and the freed ones do not go back to the OS promptly — six files
        // of tail scanning peaked at 88 MB doing it that way.
        var buffer = Data()
        buffer.reserveCapacity(chunkSize * 2)

        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)

            var lineStart = 0
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = 0
                while i < raw.count {
                    guard base[i] == 0x0A else { i += 1; continue }
                    let length = i - lineStart
                    if !overlong, length > minLength,
                       contains(base + lineStart, length, needle) {
                        // One pool per line, here rather than in each caller. Every scan ends
                        // up handing the line to JSONSerialization, which returns autoreleased
                        // Foundation objects; without a pool inside the loop they all stay
                        // alive until the sweep returns. One caller that forgot it accounted
                        // for 96 MB on its own.
                        autoreleasepool {
                            body(Data(bytes: base + lineStart, count: length))
                        }
                    }
                    overlong = false
                    i += 1
                    lineStart = i
                }
            }
            consumed += lineStart
            let tail = buffer.count - lineStart
            if tail > maxLine {
                // Give up on this line and resume at the next newline.
                overlong = true
                consumed += tail
                buffer.removeAll(keepingCapacity: true)
            } else if lineStart > 0 {
                buffer.removeSubrange(0..<lineStart)
            }
        }
        return consumed
    }

    /// The newest matching line in a file — for "the most recent record", where the caller only
    /// wants one and the file is written newest-last.
    ///
    /// `tailBytes` limits how far back to look. Whole-file scans are what these logs punish:
    /// six of them cost 88 MB and a fifth of a second answering a question about the last few
    /// hours. Starting near the end and skipping the first partial line gives the same answer
    /// for a fraction of the work — a record older than the tail is one nobody is asking about.
    static func lastMatch(_ url: URL, marker: String, minLength: Int = 40,
                          tailBytes: Int? = nil) -> Data? {
        var last: Data?
        scanTail(url, marker: marker, minLength: minLength, tailBytes: tailBytes) { last = $0 }
        return last
    }

    /// Like `scan`, but starting `tailBytes` from the end (aligned to the next line boundary).
    static func scanTail(_ url: URL, marker: String, minLength: Int = 40,
                         tailBytes: Int? = nil, body: (Data) -> Void) {
        var start = 0
        if let tailBytes,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > tailBytes {
            start = size - tailBytes
            // Step forward to the first newline so the scan never begins mid-record.
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: UInt64(start))
                if let probe = try? handle.read(upToCount: 1 << 20),
                   let nl = probe.firstIndex(of: 0x0A) {
                    start += probe.distance(from: probe.startIndex, to: nl) + 1
                }
            }
        }
        scan(url, marker: marker, from: start, minLength: minLength, body: body)
    }

    /// Naive substring search over bytes. The needle is a handful of bytes and the haystack is
    /// one line, so anything cleverer costs more to set up than it saves.
    static func contains(_ hay: UnsafePointer<UInt8>, _ n: Int, _ needle: [UInt8]) -> Bool {
        let m = needle.count
        guard m <= n, m > 0 else { return false }
        let first = needle[0]
        var i = 0
        while i <= n - m {
            if hay[i] == first {
                var k = 1
                while k < m, hay[i + k] == needle[k] { k += 1 }
                if k == m { return true }
            }
            i += 1
        }
        return false
    }
}
