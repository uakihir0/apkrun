typealias Secret = Sensitive<String>
let log = APKLogger(category: .command)
let secret = Secret("token")
let clearText = secret.value
log.info("token \(clearText, .public)")
