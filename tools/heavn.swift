#!/usr/bin/env swift
// HEAVN One Series II controller for macOS. Uses Foundation and CoreBluetooth only.
// Usage: swift heavn.swift status|on|off|toggle|test [exact Bluetooth name]
// Default device: HEAVN_One2 67a9. `test` toggles power, waits two seconds, restores it.
// Close the HEAVN phone app first. Only one controller may connect at a time.
// Commands are verified by reading the lamp's reported state; failures exit nonzero.
import Foundation
import CoreBluetooth

let arguments = Array(CommandLine.arguments.dropFirst())
let operation = arguments.first ?? "status"
let deviceName = arguments.count > 1 ? arguments[1] : "HEAVN_One2 67a9"
guard ["status", "on", "off", "toggle", "test"].contains(operation), arguments.count <= 2 else {
    fputs("Usage: swift heavn.swift status|on|off|toggle|test [exact Bluetooth name]\n", stderr)
    exit(2)
}

final class Controller: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let serviceID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    let writeID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    let notifyID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    var central: CBCentralManager!
    var lamp: CBPeripheral?
    var writer: CBCharacteristic?
    var pending: (String, (String) -> Void)?
    var queryTimer: DispatchWorkItem?
    var started = false
    var exiting = false
    var originalPower: Bool?
    var recovering = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) {
            if self.recovering { self.end(["error": "Timed out during restoration; check the lamp"], code: 1) }
            else { self.fail("Timed out; check lamp power, range, Bluetooth permission and the phone app") }
        }
    }
    func log(_ text: String) { fputs(text + "\n", stderr) }
    func end(_ result: [String: Any], code: Int32 = 0) {
        guard !exiting else { return }
        exiting = true
        queryTimer?.cancel()
        pending = nil
        central.stopScan()
        var output = result
        output["device"] = deviceName
        output["transport"] = "Bluetooth Low Energy"
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        if let p = lamp { central.cancelPeripheralConnection(p) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(code) }
    }
    func fail(_ message: String) {
        guard !exiting else { return }
        if let initial = originalPower, !recovering, lamp?.state == .connected {
            recovering = true
            pending = nil
            queryTimer?.cancel()
            log("Attempting to restore the starting power state after error: " + message)
            setPower(initial) { state in
                self.originalPower = nil
                self.end(["error": message, "starting_power_restored": true, "power_response": state], code: 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                self.end(["error": message, "starting_power_restored": false], code: 1)
            }
        } else { end(["error": message], code: 1) }
    }
    func send(_ command: String, query: Bool = false) {
        guard let p = lamp, p.state == .connected, let w = writer else { fail("Lamp disconnected"); return }
        p.writeValue(Data(command.utf8), for: w, type: query ? .withResponse : .withoutResponse)
    }
    func request(_ command: String, prefix: String, receive: @escaping (String) -> Void) {
        guard !exiting, pending == nil else { fail("Overlapping Bluetooth queries"); return }
        pending = (prefix, receive)
        let timer = DispatchWorkItem { self.pending = nil; self.fail("No response to " + command) }
        queryTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timer)
        send(command, query: true)
    }
    func state(_ receive: @escaping (String) -> Void) {
        request("@s", prefix: "$s") { value in
            guard value.count == 6, value.dropFirst(2).allSatisfy({ $0 == "0" || $0 == "1" }) else {
                self.fail("Unrecognized power response: " + value); return
            }
            receive(value)
        }
    }
    func setPower(_ desired: Bool, done: @escaping (String) -> Void) {
        state { before in
            if before.last == (desired ? "1" : "0") { done(before); return }
            self.send("@KXXXXXD")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.send("@KXXXXXU")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.state { after in
                        guard after.last == (desired ? "1" : "0") else { self.fail("Power change was not verified: " + after); return }
                        done(after)
                    }
                }
            }
        }
    }
    func run() {
        switch operation {
        case "status":
            state { power in
                self.request("@e", prefix: "$e") { mode in
                    guard ["$e0", "$e1"].contains(mode) else { self.fail("Unrecognized mode: " + mode); return }
                    self.request("@V", prefix: "$V") { firmware in
                        self.request("@Q", prefix: "$I") { brightness in
                            self.end(["powered_on": power.last == "1", "power_response": power,
                                      "automatic_mode": mode == "$e0", "firmware": String(firmware.dropFirst(2)),
                                      "brightness_response": brightness])
                        }
                    }
                }
            }
        case "on", "off":
            setPower(operation == "on") { value in self.end(["powered_on": value.last == "1", "verified": true, "power_response": value]) }
        case "toggle":
            state { before in
                self.setPower(before.last != "1") { after in self.end(["powered_on": after.last == "1", "verified": true, "power_response": after]) }
            }
        case "test":
            state { before in
                self.originalPower = before.last == "1"
                self.setPower(before.last != "1") { during in
                    self.log("Test power response: " + during + "; restoring in two seconds")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.setPower(before.last == "1") { after in
                            self.originalPower = nil
                            self.end(["before": before, "during": during, "after": after, "starting_power_restored": true])
                        }
                    }
                }
            }
        default: fail("Unsupported operation")
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [serviceID])
        } else if central.state == .unauthorized || central.state == .unsupported || central.state == .poweredOff {
            fail("Bluetooth is unavailable or permission was denied (state \(central.state.rawValue))")
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        guard lamp == nil, name == deviceName else { return }
        lamp = p
        p.delegate = self
        central.stopScan()
        central.connect(p)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([serviceID]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { fail("Connection failed: \(String(describing: error))") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if !exiting { fail("Lamp disconnected before completion; check its power state") }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = p.services?.first(where: { $0.uuid == serviceID }) else { fail("UART service unavailable"); return }
        p.discoverCharacteristics([writeID, notifyID], for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics,
              let w = chars.first(where: { $0.uuid == writeID }), let n = chars.first(where: { $0.uuid == notifyID }),
              w.properties.contains(.write), w.properties.contains(.writeWithoutResponse), n.properties.contains(.notify) else {
            fail("Required UART characteristics unavailable"); return
        }
        writer = w
        p.setNotifyValue(true, for: n)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard error == nil, c.isNotifying else { fail("Could not subscribe to lamp responses"); return }
        if !started { started = true; run() }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error = error { fail("Bluetooth write failed: \(error)") }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, c.uuid == notifyID, let data = c.value, let text = String(data: data, encoding: .utf8) else { return }
        for part in text.components(separatedBy: "$").dropFirst() {
            let frame = "$" + part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let (prefix, receive) = pending, frame.hasPrefix(prefix) {
                pending = nil
                queryTimer?.cancel()
                receive(frame)
            }
        }
    }
}
let controller = Controller()
RunLoop.main.run()
