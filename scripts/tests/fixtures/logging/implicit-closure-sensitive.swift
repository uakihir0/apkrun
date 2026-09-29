let log = APKLogger(category: .command)
let callback: (Sensitive<String>) -> Void = {
    log.info("token \($0.value, .public)")
}
