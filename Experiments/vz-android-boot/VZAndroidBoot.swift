// VZ direct-kernel boot spike for the stock Cuttlefish image (experiment only).
//
// Boots the Android kernel, the per-boot initrd, and the three GPT disks of
// android-image.md §4.2 on Virtualization.framework with the 20-port console
// plan of §7.1, vsock, and one NAT NIC. Guest output goes to files in
// --log-dir. hvc1 (the Android serial shell) reads commands from the FIFO
// <log-dir>/hvc1.in. A loopback TCP listener forwards to guest vsock 5555 so
// `adb connect 127.0.0.1:<port>` works. The production path is
// AndroidBootPlanner + VMController (#012-#015); nothing here is imported by a
// production target.

import Darwin
import Foundation
import Virtualization

struct Options {
    var kernel = ""
    var initrd = ""
    var commandLine = ""
    var disks: [(path: String, readOnly: Bool)] = []
    var cpus = 4
    var memoryMiB: UInt64 = 4096
    var logDir = ""
    var gpu = "none"
    var adbPort: UInt16 = 6520
    var timeoutSeconds: Double = 1800
    var consolePorts = 20
    var extraConsolePorts = 0
    var ioPorts: Set<Int> = []
    var sensorsPort: Int? = nil
    var nics = 1
    var nicMACs: [String] = []
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        guard let value = arguments.next() else {
            fatalError("missing value for \(argument)")
        }
        switch argument {
        case "--kernel": options.kernel = value
        case "--initrd": options.initrd = value
        case "--cmdline-file":
            options.commandLine = (try! String(contentsOfFile: value, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case "--disk":
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            options.disks.append((parts[0], parts.count > 1 && parts[1] == "ro"))
        case "--cpus": options.cpus = Int(value)!
        case "--memory-mib": options.memoryMiB = UInt64(value)!
        case "--log-dir": options.logDir = value
        case "--gpu": options.gpu = value
        case "--adb-port": options.adbPort = UInt16(value)!
        case "--timeout": options.timeoutSeconds = Double(value)!
        case "--console-ports": options.consolePorts = Int(value)!
        case "--extra-console-ports": options.extraConsolePorts = Int(value)!
        case "--io-ports": options.ioPorts = Set(value.split(separator: ",").map { Int($0)! })
        case "--sensors-port": options.sensorsPort = Int(value)!
        case "--nics": options.nics = Int(value)!
        case "--nic-macs": options.nicMACs = value.split(separator: ",").map(String.init)
        default: fatalError("unknown option \(argument)")
        }
    }
    return options
}

let options = parseOptions()
let start = Date()

func stamp() -> String {
    String(format: "%7.1fs", Date().timeIntervalSince(start))
}

func say(_ message: String) {
    FileHandle.standardOutput.write("[\(stamp())] \(message)\n".data(using: .utf8)!)
}

/// Markers echoed to stdout the first few times they appear on hvc0.
let markers: [(String, Int)] = [
    ("Booting Linux on physical CPU", 1),
    ("Kernel panic", 3),
    ("init: init first stage started!", 1),
    ("init: Switching root to '/system'", 1),
    ("init: init second stage started!", 1),
    ("starting service 'zygote'", 4),
    ("boot_progress_", 0),
    ("VIRTUAL_DEVICE_", 20),
    ("WATCHDOG", 6),
    ("Watchdog", 6),
    ("pci-host-generic", 2),
    ("by-name", 0),
    ("Failed to mount", 6),
    ("fs_mgr_do_format", 4),
    ("init: Unable to", 0),
    ("crash", 0),
    ("reboot", 4),
    ("Unable to find", 4),
    ("Timed out", 6),
]
var markerCounts: [String: Int] = [:]
let markerLock = NSLock()

func scan(line: String) {
    markerLock.lock()
    defer { markerLock.unlock() }
    for (needle, limit) in markers where line.contains(needle) {
        let count = markerCounts[needle, default: 0]
        if count < limit {
            say("hvc0: \(line.prefix(220))")
        }
        markerCounts[needle] = count + 1
        if needle == "VIRTUAL_DEVICE_" && line.contains("BOOT_COMPLETED") {
            say("BOOT COMPLETED detected on console")
        }
        break
    }
}

/// Reads guest output from `pipe`, appends it to `file`, and optionally scans lines.
func pump(_ pipe: Pipe, to path: String, scanLines: Bool) {
    FileManager.default.createFile(atPath: path, contents: nil)
    let output = FileHandle(forWritingAtPath: path)!
    let thread = Thread {
        var pending = Data()
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            output.write(data)
            guard scanLines else { continue }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                scan(line: String(decoding: lineData, as: UTF8.self))
            }
        }
    }
    thread.start()
}

/// An input pipe that is never written: guest reads block instead of seeing EOF.
var idlePipes: [Pipe] = []
func idleInput() -> FileHandle {
    let pipe = Pipe()
    idlePipes.append(pipe)
    return pipe.fileHandleForReading
}

func fifoInput(path: String) -> FileHandle {
    unlink(path)
    guard mkfifo(path, 0o600) == 0 else { fatalError("mkfifo \(path): \(errno)") }
    let readFD = open(path, O_RDONLY | O_NONBLOCK)
    let keepAlive = open(path, O_WRONLY)
    guard readFD >= 0, keepAlive >= 0 else { fatalError("open fifo \(path): \(errno)") }
    let flags = fcntl(readFD, F_GETFL)
    _ = fcntl(readFD, F_SETFL, flags & ~O_NONBLOCK)
    return FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
}

try! FileManager.default.createDirectory(atPath: options.logDir, withIntermediateDirectories: true)

let configuration = VZVirtualMachineConfiguration()
let platform = VZGenericPlatformConfiguration()
platform.machineIdentifier = VZGenericMachineIdentifier()
configuration.platform = platform
let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: options.kernel))
bootLoader.initialRamdiskURL = URL(fileURLWithPath: options.initrd)
bootLoader.commandLine = options.commandLine
configuration.bootLoader = bootLoader
configuration.cpuCount = options.cpus
configuration.memorySize = options.memoryMiB * 1024 * 1024

configuration.storageDevices = options.disks.map { disk in
    let attachment = try! VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: disk.path),
        readOnly: disk.readOnly,
        cachingMode: .automatic,
        synchronizationMode: disk.readOnly ? .none : .fsync
    )
    return VZVirtioBlockDeviceConfiguration(attachment: attachment)
}

let portLogs = [0: "console.log", 1: "hvc1.log", 2: "logcat.log"]

/// "No sensors" substitute for the Cuttlefish sensors HAL control port (hvc18).
/// Frames are `u32 command | is_response << 31, u32 payload size, payload`, all
/// little-endian (common/libs/transport/channel.h, android17-release).
/// `list-sensors` gets the reply the real sensors_simulator sends for mask 0:
/// command 2 (kUpdateHal) with is_response set and payload "0\n". Other
/// commands (`time:`, `set-delay:`, `set:`) need no answer.
func sensorsResponder(index: Int) -> VZFileHandleSerialPortAttachment {
    let toGuest = Pipe()
    let fromGuest = Pipe()
    let trace = FileHandle(
        forWritingAtPath: {
            let path = options.logDir + "/hvc\(index).out"
            FileManager.default.createFile(atPath: path, contents: nil)
            return path
        }())!
    Thread {
        var buffer = Data()
        while true {
            let data = fromGuest.fileHandleForReading.availableData
            if data.isEmpty { break }
            trace.write(data)
            buffer.append(data)
            while buffer.count >= 8 {
                let bytes = [UInt8](buffer.prefix(8))
                let length = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
                guard buffer.count >= 8 + length else { break }
                let payload = String(decoding: buffer.dropFirst(8).prefix(length), as: UTF8.self)
                buffer.removeFirst(8 + length)
                say("sensors: guest sent '\(payload)'")
                if payload.hasPrefix("list-sensors") {
                    let reply = Data("0\n".utf8)
                    var frame = Data([0x02, 0x00, 0x00, 0x80])
                    frame.append(contentsOf: [UInt8(reply.count), 0, 0, 0])
                    frame.append(reply)
                    toGuest.fileHandleForWriting.write(frame)
                    say("sensors: answered list-sensors with mask 0")
                }
            }
        }
    }.start()
    return VZFileHandleSerialPortAttachment(
        fileHandleForReading: toGuest.fileHandleForReading,
        fileHandleForWriting: fromGuest.fileHandleForWriting
    )
}

/// The host side of guest port `index` (its hvc number, assuming array order).
/// hvc0-2 are logged; `--io-ports` ports read a FIFO `hvcN.in` and log to `hvcN.out`.
func attachment(forPort index: Int) -> VZFileHandleSerialPortAttachment {
    if index == options.sensorsPort { return sensorsResponder(index: index) }
    let interactive = index == 1 || options.ioPorts.contains(index)
    let reading = interactive ? fifoInput(path: options.logDir + "/hvc\(index).in") : idleInput()
    let writing: FileHandle
    if let name = portLogs[index] ?? (interactive ? "hvc\(index).out" : nil) {
        let pipe = Pipe()
        pump(pipe, to: options.logDir + "/" + name, scanLines: index == 0)
        writing = pipe.fileHandleForWriting
    } else {
        writing = FileHandle(forWritingAtPath: "/dev/null")!
    }
    return VZFileHandleSerialPortAttachment(fileHandleForReading: reading, fileHandleForWriting: writing)
}

configuration.serialPorts = (0..<options.consolePorts).map { index in
    let port = VZVirtioConsoleDeviceSerialPortConfiguration()
    port.attachment = attachment(forPort: index)
    return port
}

// Ports beyond the single-port device limit: one multiport virtio-console
// device whose ports are all flagged as consoles, so Linux gives each an hvc.
if options.extraConsolePorts > 0 {
    let console = VZVirtioConsoleDeviceConfiguration()
    for index in 0..<options.extraConsolePorts {
        let port = VZVirtioConsolePortConfiguration()
        port.isConsole = true
        port.name = "hvc\(options.consolePorts + index)"
        port.attachment = attachment(forPort: options.consolePorts + index)
        console.ports[index] = port
    }
    configuration.consoleDevices = [console]
}

// Cuttlefish's NIC order: eth0 is the mobile NIC (renamed buried_eth0 for the
// RIL), eth1 the ethernet NIC that the OpenThread simulator RCP binds to, and
// eth2 the virt_wifi backing NIC. setup_wifi rewrites eth2's MAC from
// androidboot.wifi_mac_prefix, and vmnet drops frames from a MAC it did not
// assign, so --nic-macs must give eth2 that MAC up front.
configuration.networkDevices = (0..<options.nics).map { index in
    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()
    let mac =
        index < options.nicMACs.count
        ? options.nicMACs[index] : String(format: "02:a5:4b:00:00:%02x", index + 1)
    network.macAddress = VZMACAddress(string: mac)!
    return network
}
configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

if options.gpu == "vz2d" {
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 720, heightInPixels: 1280)]
    configuration.graphicsDevices = [graphics]
}

do {
    try configuration.validate()
} catch {
    say("configuration invalid: \(error)")
    exit(2)
}

let queue = DispatchQueue(label: "io.apkrun.experiment.vz-android-boot")
var machine: VZVirtualMachine!

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        say("guest stopped")
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        say("VM stopped with error: \(error)")
        exit(1)
    }
}
let delegate = Delegate()

/// Forwards 127.0.0.1:<port> to guest vsock 5555 for adb.
func startADBForwarder() {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = options.adbPort.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(listener, 8) == 0 else {
        say("adb forwarder: bind/listen failed (\(errno))")
        return
    }
    say("adb forwarder: 127.0.0.1:\(options.adbPort) -> vsock 5555")
    Thread {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            queue.async {
                guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
                    close(client)
                    return
                }
                device.connect(toPort: 5555) { result in
                    switch result {
                    case .success(let connection):
                        splice(client, connection)
                    case .failure:
                        close(client)
                    }
                }
            }
        }
    }.start()
}

var liveConnections: [VZVirtioSocketConnection] = []
let connectionLock = NSLock()

func splice(_ client: Int32, _ connection: VZVirtioSocketConnection) {
    connectionLock.lock()
    liveConnections.append(connection)
    connectionLock.unlock()
    let guest = connection.fileDescriptor
    func copy(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(from, &buffer, buffer.count)
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(to, $0.baseAddress! + offset, count - offset)
                }
                if written <= 0 { return }
                offset += written
            }
        }
        shutdown(to, SHUT_WR)
    }
    let done = DispatchGroup()
    for (from, to) in [(client, guest), (guest, client)] {
        done.enter()
        Thread {
            copy(from, to)
            done.leave()
        }.start()
    }
    done.notify(queue: .global()) {
        close(client)
        connection.close()
        connectionLock.lock()
        liveConnections.removeAll { $0 === connection }
        connectionLock.unlock()
    }
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let stopSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        say("signal \(number): stopping VM")
        queue.async {
            machine.stop { _ in exit(130) }
        }
    }
    source.resume()
    return source
}

queue.async {
    machine = VZVirtualMachine(configuration: configuration, queue: queue)
    machine.delegate = delegate
    machine.start { result in
        switch result {
        case .success:
            say("VM started (\(options.cpus) vCPU, \(options.memoryMiB) MiB, gpu \(options.gpu))")
            startADBForwarder()
        case .failure(let error):
            say("start failed: \(error)")
            exit(1)
        }
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + options.timeoutSeconds) {
    say("timeout after \(Int(options.timeoutSeconds)) s: stopping VM")
    queue.async {
        machine.stop { _ in exit(3) }
    }
}

dispatchMain()
