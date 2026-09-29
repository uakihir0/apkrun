let log = APKLogger(category: .command)
let secret: Sensitive<String> = Sensitive("token")
let clearText = secret.value
log.info("using \(clearText, .private)")
