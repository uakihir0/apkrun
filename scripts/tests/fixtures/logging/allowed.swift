// print("comments do not count as calls")
let count = 1; /* os.Logger and Logger.init() in block comments do not count */
let description = "os.Logger Logger( NSLog( os_log("
let log = APKLogger(category: .command)
let packageID = "package.name"
log.info("launching \(packageID, .public)")
log.debug("fixture \(description, LogPrivacy.private)")
log.info("comment \(packageID, .public /* safe */)")

typealias StringHandler<T> = (T) -> Void
let stringHandler: StringHandler<String> = { [log] value in
    log.info("value \(value, .public)")
}

struct Holder {
    let logger: APKLogger
}
let wrapper = Holder(logger: log)
wrapper.info("value \(packageID)")
