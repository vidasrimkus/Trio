import Foundation

/// Reads the bytes a log file gained since the last successful shipment. Pure file logic — no
/// network, no app state. The log files themselves are the buffer: nothing is copied, the only
/// thing persisted is a per-stream offset.
///
/// Both Trio (`SimpleLogReporter`) and DanaKit (`DanaLogWriter`) rotate the same way: on the first
/// write of a new day `current` is moved to `previous` (inode kept) and a fresh `current` is created.
struct LogTailReader {
    /// `inode:creationDate` — survives the rename at rotation and differs for every fresh file.
    struct FileInfo: Equatable {
        let id: String
        let size: Int
    }

    struct StreamState: Codable, Equatable {
        var fileId: String?
        var offset: Int
        /// A gap was detected but nothing could be shipped yet (empty file); the next batch carries it.
        var gapPending: Bool

        init(fileId: String? = nil, offset: Int = 0, gapPending: Bool = false) {
            self.fileId = fileId
            self.offset = offset
            self.gapPending = gapPending
        }

        private enum CodingKeys: String, CodingKey {
            case fileId
            case offset
            case gapPending
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fileId = try container.decodeIfPresent(String.self, forKey: .fileId)
            offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
            gapPending = try container.decodeIfPresent(Bool.self, forKey: .gapPending) ?? false
        }
    }

    struct Batch: Equatable {
        let fileId: String
        let from: Int
        let to: Int
        /// Bytes before `from` were lost (missed rotation, truncated file).
        let gapBefore: Bool
        let data: Data
    }

    struct Result: Equatable {
        /// Nothing to send when nil.
        let batch: Batch?
        /// State to persist once `batch` has been accepted (or right away when `batch` is nil).
        let stateAfterSuccess: StreamState
    }

    let currentURL: URL
    let previousURL: URL

    static func info(of url: URL) -> FileInfo? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        let created = (attributes[.creationDate] as? Date).map { Int64($0.timeIntervalSince1970) } ?? 0
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return FileInfo(id: "\(inode):\(created)", size: size)
    }

    /// Next batch for a stream. At most `limit` bytes, cut at the last newline. One batch per call:
    /// after a rotation the rest of `previous` is finished first, the new file starts on the next call.
    func next(state: StreamState, limit: Int) -> Result {
        guard let current = Self.info(of: currentURL) else {
            return Result(batch: nil, stateAfterSuccess: state)
        }

        var state = state
        var gap = state.gapPending

        if state.fileId == nil {
            state = StreamState(fileId: current.id, offset: 0)
        }

        if state.fileId != current.id {
            if let previous = Self.info(of: previousURL), previous.id == state.fileId {
                if state.offset > previous.size {
                    state.offset = 0
                    gap = true
                }
                if state.offset < previous.size {
                    // Nothing writes to the rotated file any more: its last line never gains a newline.
                    return read(from: previousURL, info: previous, state: state, gap: gap, limit: limit, final: true)
                }
                state = StreamState(fileId: current.id, offset: 0)
            } else {
                state = StreamState(fileId: current.id, offset: 0)
                gap = true
            }
        }

        if state.offset > current.size {
            state.offset = 0
            gap = true
        }

        return read(from: currentURL, info: current, state: state, gap: gap, limit: limit, final: false)
    }

    private func read(from url: URL, info: FileInfo, state: StreamState, gap: Bool, limit: Int, final: Bool) -> Result {
        // Nothing to ship yet: keep the (normalized) state and remember the gap for the next batch.
        let waiting = Result(batch: nil, stateAfterSuccess: StreamState(fileId: state.fileId, offset: state.offset, gapPending: gap))

        guard limit > 0, state.offset < info.size,
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            return waiting
        }
        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: UInt64(state.offset))) != nil,
              var data = try? handle.read(upToCount: limit), !data.isEmpty
        else {
            return waiting
        }

        if let newline = data.lastIndex(of: 0x0A) {
            data = data.prefix(newline - data.startIndex + 1)
        } else if data.count < limit, !final {
            // A line still being written — wait for its newline.
            return waiting
        }

        let batch = Batch(
            fileId: info.id,
            from: state.offset,
            to: state.offset + data.count,
            gapBefore: gap,
            data: Data(data)
        )
        return Result(batch: batch, stateAfterSuccess: StreamState(fileId: info.id, offset: batch.to, gapPending: false))
    }
}
