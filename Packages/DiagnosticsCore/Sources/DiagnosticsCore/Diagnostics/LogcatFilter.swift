import Foundation

/// The host-side logcat filter of diagnostics.md §8.3. The agent dumps with
/// `-v threadtime,uid,UTC,year`; the host keeps system-UID lines (UID below
/// 10000), APKRun-tagged lines, and, from app UIDs, only the crash-buffer
/// lines of a fatal exception. `includeLogcat` keeps everything, still
/// redacted by the writer.
public enum LogcatFilter {
    /// The tags a report always keeps: APKRun's own processes.
    private static let keptTags: Set<String> = [
        "apkrun", "apkrun.guestd", "apkrun.store", "apkrun.ime",
        "apkrun.vsockd", "AndroidRuntime",
    ]

    /// Filters logcat `text` per §8.3. When `includeAll` is set the text is
    /// returned unchanged (redaction still applies downstream).
    public static func filter(_ text: String, includeAll: Bool) -> String {
        if includeAll {
            return text
        }
        var kept: [String] = []
        var inFatalBlock = false
        var fatalLinesLeft = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let parsed = parse(String(line))
            // A fatal exception keeps the block: FATAL EXCEPTION, Process:,
            // the exception line, and the stack frames that follow.
            if let parsed {
                if parsed.uid < 10_000 || keptTags.contains(parsed.tag) {
                    kept.append(String(line))
                    inFatalBlock = parsed.message.hasPrefix("FATAL EXCEPTION")
                    fatalLinesLeft = inFatalBlock ? 200 : 0
                    continue
                }
                if inFatalBlock, fatalLinesLeft > 0 {
                    kept.append(String(line))
                    fatalLinesLeft -= 1
                    if parsed.message.hasPrefix("Process:") {
                        // `Process:` and the exception lines stay inside the block.
                        continue
                    }
                    continue
                }
                if parsed.message.hasPrefix("FATAL EXCEPTION") {
                    kept.append(String(line))
                    inFatalBlock = true
                    fatalLinesLeft = 200
                    continue
                }
            }
        }
        return kept.joined(separator: "\n")
    }

    /// One parsed `threadtime,uid` line: date, time, pid, tid, uid, level, tag,
    /// message. `uid` is the numeric Android UID when present.
    struct ParsedLine {
        /// The numeric UID (`uid` field), or the process UID when absent.
        let uid: Int
        /// The log tag.
        let tag: String
        /// The message after the tag.
        let message: String
    }

    /// Parses `-v threadtime,uid,UTC,year` output:
    /// `2026-09-28 10:15:02.123  1234  1235  1000 I Tag: message`.
    /// Returns nil for lines that do not match (headers, `---------` markers).
    static func parse(_ line: String) -> ParsedLine? {
        // threadtime: YYYY-MM-DD HH:MM:SS.mmm
        guard line.count > 30 else { return nil }
        var index = line.startIndex
        func skipSpaces() {
            while index < line.endIndex, line[index] == " " {
                index = line.index(after: index)
            }
        }
        func token() -> String {
            skipSpaces()
            var end = index
            while end < line.endIndex, line[end] != " " {
                end = line.index(after: end)
            }
            let value = String(line[index..<end])
            index = end
            return value
        }
        _ = token()  // date
        _ = token()  // time
        _ = token()  // pid
        _ = token()  // tid
        let uidToken = token()
        let level = token()
        guard level.count == 1, "VDIWEF".contains(level) else { return nil }
        guard let uid = Int(uidToken) else { return nil }
        skipSpaces()
        let rest = String(line[index...])
        let tagEnd = rest.firstIndex(of: ":") ?? rest.endIndex
        var tag = String(rest[..<tagEnd]).trimmingCharacters(in: .whitespaces)
        var message = rest
        if tagEnd < rest.endIndex {
            message = String(rest[rest.index(after: tagEnd)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            tag = rest
            message = ""
        }
        return ParsedLine(uid: uid, tag: tag, message: message)
    }
}
