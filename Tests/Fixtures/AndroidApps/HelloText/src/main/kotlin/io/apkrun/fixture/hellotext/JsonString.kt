package io.apkrun.fixture.hellotext

/** The JSON string literal of a text (test-strategy §4.2, the `text <JSON string>` event). */
object JsonString {
    /** The literal of [text], with quotes, backslashes, and control characters escaped. */
    fun encode(text: String): String {
        val out = StringBuilder("\"")
        for (ch in text) {
            when {
                ch == '"' -> out.append("\\\"")
                ch == '\\' -> out.append("\\\\")
                ch == '\n' -> out.append("\\n")
                ch == '\r' -> out.append("\\r")
                ch == '\t' -> out.append("\\t")
                ch < ' ' -> out.append("\\u%04x".format(ch.code))
                else -> out.append(ch)
            }
        }
        return out.append('"').toString()
    }
}
