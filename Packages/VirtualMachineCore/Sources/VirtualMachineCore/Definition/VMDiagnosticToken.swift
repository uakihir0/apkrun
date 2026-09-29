/// Bounds caller-supplied labels before they enter public diagnostics.
enum VMDiagnosticToken {
    static func sanitize(_ value: String, maximumLength: Int = 64) -> String {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= maximumLength else {
            return "redacted"
        }
        guard
            bytes.allSatisfy({ byte in
                (0x30...0x39).contains(byte)
                    || (0x41...0x5A).contains(byte)
                    || (0x61...0x7A).contains(byte)
                    || byte == 0x2E
                    || byte == 0x5F
                    || byte == 0x2D
            }), value != ".", value != ".."
        else {
            return "redacted"
        }
        return value
    }
}
