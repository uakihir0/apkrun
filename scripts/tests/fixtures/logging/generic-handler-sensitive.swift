typealias Handler<T> = (T) -> Void
let log = APKLogger(category: .command)
let callback: Handler<Sensitive<String>> = { [log] secret in
    log.info("token \(secret.value, .public)")
}
