import Foundation

/// Finds the JSON lines worth decoding in a large append-only log.
///
/// Every provider here reads JSONL files that run to tens of megabytes, and in all of them the
/// lines we want are a small fraction of the total. The obvious approach — read as `String`,
/// `split` on newlines, test each line with `contains` — spends nearly all of its time in
/// Unicode-correct comparison while *rejecting* lines. Scanning raw bytes for an ASCII marker
/// and decoding only the survivors turned a several-second sweep into a fraction of one.
///
/// Files are memory-mapped, so a large log is never fully resident.
enum LineScanner {

    /// Calls `body` for each line containing `marker`, in file order.
    /// Returns the offset just past the last **complete** line — a log being appended to can end
    /// mid-line, and resuming from inside one would produce garbage on the next pass.
    @discardableResult
    static func scan(_ url: URL, marker: String, from offset: Int = 0,
                     minLength: Int = 40, body: (Data) -> Void) -> Int {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              offset <= data.count else { return 0 }
        let needle = Array(marker.utf8)
        var end = offset

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var lineStart = offset
            var i = offset
            while i < raw.count {
                guard base[i] == 0x0A else { i += 1; continue }
                let length = i - lineStart
                if length > minLength, contains(base + lineStart, length, needle) {
                    body(Data(bytes: base + lineStart, count: length))
                }
                i += 1
                lineStart = i
                end = i                      // only advances past a real newline
            }
        }
        return end
    }

    /// Same scan, but walking backwards through the matches — for "the newest record in this
    /// file", where reading the whole file forwards would be wasted work.
    static func lastMatch(_ url: URL, marker: String, minLength: Int = 40) -> Data? {
        var last: Data?
        scan(url, marker: marker, minLength: minLength) { last = $0 }
        return last
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
