import AppKit
import CoreBluetooth

// Native motion-timeout override. No brightness, temperature, scene or clock writes.
struct LampState {
    let presence: String
    let automatic: Bool
    let on: Bool
    var motionEnabled: Bool { presence.hasPrefix("$O1:") }
}

final class LampConnection: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let name = "HEAVN_One2 67a9"
    private let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private var manager: CBCentralManager!
    private var lamp: CBPeripheral?
    private var writer: CBCharacteristic?
    private var pending: (String, (String) -> Void)?
    private var timeout: DispatchWorkItem?
    private var overall: DispatchWorkItem?
    private var complete = false
    private var started = false
    private let enable: Bool
    private let restore: String?
    private let beforeWrite: (String) -> Void
    private let finished: (Result<LampState, Error>) -> Void

    init(enable: Bool = false, restore: String? = nil,
         beforeWrite: @escaping (String) -> Void = { _ in },
         finished: @escaping (Result<LampState, Error>) -> Void) {
        self.enable = enable; self.restore = restore
        self.beforeWrite = beforeWrite; self.finished = finished
        super.init()
        let deadline = DispatchWorkItem { [weak self] in self?.fail("Connection timed out. Check lamp range and close the HEAVN app.") }
        overall = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: deadline)
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    static func validPresence(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 9 && bytes[0] == 36 && bytes[1] == 79
            && (bytes[2] == 48 || bytes[2] == 49) && bytes[3] == 58
            && bytes[4...8].allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private func finish(_ result: Result<LampState, Error>) {
        guard !complete else { return }; complete = true
        timeout?.cancel(); overall?.cancel(); pending = nil
        manager.stopScan()
        if let lamp { manager.cancelPeripheralConnection(lamp) }
        // Let CoreBluetooth close before the next menu action can start a connection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.finished(result) }
    }
    private func fail(_ text: String) {
        finish(.failure(NSError(domain: "HEAVN", code: 1, userInfo: [NSLocalizedDescriptionKey: text])))
    }
    private func send(_ text: String, key: Bool = false) {
        guard !complete else { return }
        guard let lamp, lamp.state == .connected, let writer else { fail("Lamp disconnected."); return }
        lamp.writeValue(Data(text.utf8), for: writer, type: key ? .withoutResponse : .withResponse)
    }
    private func query(_ text: String, prefix: String, reply: @escaping (String) -> Void) {
        guard !complete else { return }
        guard pending == nil else { fail("Overlapping Bluetooth requests."); return }
        pending = (prefix, reply)
        let deadline = DispatchWorkItem { [weak self] in self?.fail("Lamp did not answer \(text). Try again with the HEAVN app closed.") }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: deadline)
        send(text)
    }
    private func read(_ reply: @escaping (LampState) -> Void) {
        query("@o", prefix: "$O") { presence in
            guard Self.validPresence(presence) else { self.fail("Unexpected motion setting: \(presence)"); return }
            self.query("@e", prefix: "$e") { mode in
                guard mode == "$e0" || mode == "$e1" else { self.fail("Unexpected lighting mode."); return }
                self.query("@s", prefix: "$s") { power in
                    guard power.count == 6, power.dropFirst(2).allSatisfy({ $0 == "0" || $0 == "1" }) else {
                        self.fail("Unexpected power response."); return
                    }
                    reply(LampState(presence: presence, automatic: mode == "$e0", on: power.last == "1"))
                }
            }
        }
    }
    private func run() {
        read { state in
            if !self.enable && self.restore == nil { self.finish(.success(state)); return }
            if self.enable && !state.automatic {
                self.fail("Select automatic lighting in the HEAVN app first, then close that app and try again."); return
            }
            let desired = self.restore ?? "$O0:" + state.presence.dropFirst(4)
            guard Self.validPresence(desired) else { self.fail("Saved motion setting is invalid."); return }
            if self.enable { self.beforeWrite(state.presence) }
            self.send("@" + desired.dropFirst())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.query("@o", prefix: "$O") { actual in
                    guard actual == desired else { self.fail("The lamp did not confirm the motion setting."); return }
                    if self.enable && !state.on {
                        self.send("@KXXXXXD", key: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            self.send("@KXXXXXU", key: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.verify(desired) }
                        }
                    } else { self.verify(desired) }
                }
            }
        }
    }
    private func verify(_ desired: String) {
        read { final in
            guard final.presence == desired else { self.fail("Motion setting verification failed."); return }
            if self.enable && (!final.automatic || !final.on) {
                self.fail("Motion override was written, but automatic mode and power could not both be verified. Turn the toggle off to restore."); return
            }
            self.finish(.success(final))
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !complete else { return }
        switch central.state {
        case .poweredOn: central.scanForPeripherals(withServices: [service])
        case .unauthorized: fail("Allow HEAVN Keep Awake in System Settings → Privacy & Security → Bluetooth.")
        case .poweredOff: fail("Turn on Bluetooth to reach the lamp.")
        case .unsupported: fail("Bluetooth Low Energy is unavailable.")
        default: break
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        guard !complete, lamp == nil, name == Self.name else { return }
        lamp = p; p.delegate = self; central.stopScan(); central.connect(p)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([service]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { fail("Could not connect to the lamp.") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !complete { fail("Lamp disconnected. The saved motion setting is retained for restoration.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !complete else { return }
        guard error == nil, let uart = peripheral.services?.first(where: { $0.uuid == service }) else { fail("Lamp service unavailable."); return }
        peripheral.discoverCharacteristics([rx, tx], for: uart)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !complete else { return }
        guard error == nil, let chars = service.characteristics,
              let writer = chars.first(where: { $0.uuid == rx }), let reader = chars.first(where: { $0.uuid == tx }),
              writer.properties.contains(.write), writer.properties.contains(.writeWithoutResponse), reader.properties.contains(.notify)
        else { fail("Lamp UART characteristics unavailable."); return }
        self.writer = writer; peripheral.setNotifyValue(true, for: reader)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !complete else { return }
        guard error == nil, characteristic.isNotifying else { fail("Could not receive lamp responses."); return }
        if !started { started = true; run() }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("Bluetooth write failed: \(error.localizedDescription)") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !complete, error == nil, characteristic.uuid == tx, let value = characteristic.value,
              let text = String(data: value, encoding: .utf8) else { return }
        for part in text.components(separatedBy: "$").dropFirst() {
            let frame = "$" + part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let (prefix, reply) = pending, frame.hasPrefix(prefix) {
                pending = nil; timeout?.cancel(); reply(frame)
            }
        }
    }
}

final class MenuApp: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let toggle = NSMenuItem(title: "Keep Lamp On", action: #selector(toggleOverride), keyEquivalent: "")
    private let status = NSMenuItem(title: "Checking lamp…", action: nil, keyEquivalent: "")
    private var refresh: NSMenuItem!
    private var quit: NSMenuItem!
    private var connection: LampConnection?
    private var timer: Timer?
    private var quitting = false
    private let defaults = UserDefaults.standard
    private let journalKey = "originalPresenceBeforeOverride"
    private var original: String? { defaults.string(forKey: journalKey) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let sameApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        guard sameApps.count <= 1 else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = " HEAVN"
        let menu = NSMenu()
        let title = NSMenuItem(title: "HEAVN One · Automatic Lighting", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        toggle.target = self; menu.addItem(toggle)
        status.isEnabled = false; menu.addItem(status)
        menu.addItem(.separator())
        refresh = NSMenuItem(title: "Refresh Lamp Status", action: #selector(refreshStatus), keyEquivalent: "r")
        refresh.target = self; menu.addItem(refresh)
        let about = NSMenuItem(title: "How It Works…", action: #selector(explain), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        menu.addItem(.separator())
        quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        render()
        if CommandLine.arguments.contains("--enable") && original == nil { toggleOverride() }
        else { refreshStatus() }
        // Only observe after setup. The lamp itself disables the motion timeout.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshStatus() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshStatus), name: NSWorkspace.didWakeNotification, object: nil)
    }
    private func render() {
        toggle.state = original == nil ? .off : .on
        toggle.isEnabled = connection == nil
        refresh?.isEnabled = connection == nil
        quit?.isEnabled = connection == nil
        item.button?.image = NSImage(systemSymbolName: original == nil ? "lightbulb" : "lightbulb.fill", accessibilityDescription: "HEAVN lamp")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "HEAVN: " + status.title
    }
    private func transact(enable: Bool = false, restore: String? = nil, done: (() -> Void)? = nil) {
        guard connection == nil else { return }
        status.title = enable ? "Pausing motion timeout…" : restore != nil ? "Restoring motion timeout…" : "Checking lamp…"
        connection = LampConnection(enable: enable, restore: restore, beforeWrite: { presence in
            // Journal before any write, so a crash or lost connection cannot lose the original.
            if self.original == nil { self.defaults.set(presence, forKey: self.journalKey); self.defaults.synchronize() }
        }) { result in
            self.connection = nil
            switch result {
            case .success(let lamp):
                if restore != nil { self.defaults.removeObject(forKey: self.journalKey); self.defaults.synchronize() }
                let lighting = lamp.automatic ? "Auto lighting" : "Manual lighting"
                self.status.title = lighting + (lamp.motionEnabled ? " · Motion timeout on" : " · Motion timeout paused")
                self.render()
                done?()
            case .failure(let error):
                self.status.title = "Needs attention — try Refresh"
                self.render()
                if enable || restore != nil {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t finish the lamp change"
                    alert.informativeText = error.localizedDescription + (self.original == nil ? "" : "\n\nThe original setting is saved. Turn Keep Lamp On off to restore it.")
                    alert.runModal()
                }
                if self.quitting {
                    self.quitting = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
        }
        render()
    }
    @objc private func toggleOverride() {
        if let original { transact(restore: original) }
        else { transact(enable: true) }
    }
    @objc private func refreshStatus() { if !quitting { transact() } }
    @objc private func explain() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep the light, keep automatic lighting"
        alert.informativeText = "Keep Lamp On pauses the lamp’s motion timeout and turns the lamp on. Its automatic brightness and colour schedule stays active.\n\nTurning the toggle off or quitting restores the previous motion setting without turning the light off. The Mac can sleep after the setting is applied.\n\nIf the app is force-quit or the lamp is out of range, the override may remain until you reopen this app and turn the toggle off. Close the HEAVN phone app while changing settings."
        alert.runModal()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let original else { return .terminateNow }
        guard connection == nil else { return .terminateCancel }
        if quitting { return .terminateCancel }
        quitting = true
        transact(restore: original) { NSApp.reply(toApplicationShouldTerminate: true) }
        // On failure, the callback cancels termination and retains the journal.
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = MenuApp()
app.delegate = delegate
app.run()
