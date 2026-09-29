typealias Secret<T> = Sensitive<T>
let log = APKLogger(category: .command)
let secret = Secret<String>("token")
let clearText = secret.value
log.info("token \(clearText, .public)")
