//
//  NikonBluetoothGPSService.swift
//  ZLinks
//

import Combine
import CommonCrypto
import CoreBluetooth
import CoreLocation
import Foundation

/// Nikon Z smart-device BLE GPS transport.
///
/// The Nikon protocol is reverse engineered and requires an OS Bluetooth
/// Classic bond after the BLE handshake. CoreBluetooth cannot create or
/// enumerate arbitrary Classic bonds, so this service intentionally exposes
/// that limitation and still supports GEO writes when an existing bond makes
/// the characteristic writable.
@MainActor
final class NikonBluetoothGPSService: NSObject, ObservableObject {
    enum State: Equatable {
        case unavailable
        case idle
        case scanning
        case connecting
        case pairing
        case reconnecting
        case ready
        case failed(String)

        var title: String {
            switch self {
            case .unavailable: return "蓝牙不可用"
            case .idle: return "未连接"
            case .scanning, .connecting, .pairing: return "连接中"
            case .reconnecting: return "重新连接"
            case .ready: return "连接成功"
            case .failed: return "连接失败"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var cameraName: String?
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastError: String?

    var connectionStepDescription: String {
        switch state {
        case .unavailable: return "请打开蓝牙并允许定位权限。"
        case .idle: return "点击连接后，手机会持续向相机同步定位。"
        case .scanning: return "正在搜索 Nikon Smart Device。"
        case .connecting: return "正在建立相机的 BLE 连接并发现服务。"
        case .pairing: return "正在完成 Nikon 配对握手并等待相机确认。"
        case .reconnecting: return "相机连接已中断，正在自动重新连接。"
        case .ready: return "手机会持续向相机推送最近一次定位。"
        case .failed:
            return "首次连接或曾使用过 SnapBridge，请前往设置手动忽略相机蓝牙。"
        }
    }

    static let serviceUUID = CBUUID(string: "0000DE00-3DD4-4255-8D62-6DC7B9BD5561")
    private static let pairUUID = CBUUID(string: "00002000-3DD4-4255-8D62-6DC7B9BD5561")
    private static let idUUID = CBUUID(string: "00002002-3DD4-4255-8D62-6DC7B9BD5561")
    private static let geoUUID = CBUUID(string: "00002007-3DD4-4255-8D62-6DC7B9BD5561")
    private static let not1UUID = CBUUID(string: "00002008-3DD4-4255-8D62-6DC7B9BD5561")

    private lazy var central = CBCentralManager(
        delegate: self,
        queue: .main,
        options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
            CBCentralManagerOptionRestoreIdentifierKey: "cn.bptpw.ZLinks.nikon-gps-central"
        ]
    )
    private let locationManager = CLLocationManager()
    private var peripheral: CBPeripheral?
    private var pairCharacteristic: CBCharacteristic?
    private var idCharacteristic: CBCharacteristic?
    private var geoCharacteristic: CBCharacteristic?
    private var not1Characteristic: CBCharacteristic?
    private var reconnectTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var idWriteTask: Task<Void, Never>?
    private var pairingConfirmationTask: Task<Void, Never>?
    private var pendingStage1: Data?
    private var stage1Timestamp: UInt64 = 0
    private var stage1Device: UInt32 = 0
    private var stage1Nonce: UInt32 = 0
    private var matchedSaltIndex: Int?
    private var pairNotificationsEnabled = false
    private var not1NotificationsEnabled = false
    private var canWriteGeo = false
    private var didReceiveStage4 = false
    private var didReceivePairingSuccess = false
    private var didWriteControllerID = false
    private var logHandler: ((String) -> Void)?
    private var shouldStayConnected = false
    private static let controllerDeviceKey = "nikon.ble.controller.device"
    private static let controllerNonceKey = "nikon.ble.controller.nonce"
    private static let peripheralIdentifierKey = "nikon.ble.peripheral.identifier"

    init(logHandler: ((String) -> Void)? = nil) {
        self.logHandler = logHandler
        super.init()
        _ = central
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        locationManager.activityType = .otherNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func setLogHandler(_ handler: ((String) -> Void)?) { logHandler = handler }

    func start() {
        shouldStayConnected = true
        lastError = nil
        requestLocationAuthorization()
        locationManager.startUpdatingLocation()
        guard central.state == .poweredOn else {
            state = central.state == .unsupported || central.state == .unauthorized ? .unavailable : .connecting
            appendLog("[ble-gps] 等待蓝牙可用 state=\(centralStateName)")
            return
        }
        if !connectToKnownPeripheralIfAvailable() { scan() }
    }

    func retry() {
        shouldStayConnected = true
        lastError = nil
        requestLocationAuthorization()
        locationManager.startUpdatingLocation()
        guard central.state == .poweredOn else {
            state = .connecting
            return
        }
        if !connectToKnownPeripheralIfAvailable() { scan() }
    }

    @discardableResult
    private func connectToKnownPeripheralIfAvailable() -> Bool {
        guard let rawIdentifier = UserDefaults.standard.string(forKey: Self.peripheralIdentifierKey),
              let identifier = UUID(uuidString: rawIdentifier),
              let knownPeripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first
        else { return false }
        peripheral = knownPeripheral
        cameraName = knownPeripheral.name ?? cameraName
        knownPeripheral.delegate = self
        state = .connecting
        appendLog("[ble-gps] 尝试恢复已保存的相机标识")
        central.connect(knownPeripheral, options: connectionOptions)
        return true
    }

    func disconnect() {
        shouldStayConnected = false
        reconnectTask?.cancel(); reconnectTask = nil
        syncTask?.cancel(); syncTask = nil
        idWriteTask?.cancel(); idWriteTask = nil
        pairingConfirmationTask?.cancel(); pairingConfirmationTask = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        pairCharacteristic = nil; idCharacteristic = nil; geoCharacteristic = nil; not1Characteristic = nil
        pairNotificationsEnabled = false; not1NotificationsEnabled = false
        canWriteGeo = false
        didReceiveStage4 = false; didReceivePairingSuccess = false; didWriteControllerID = false
        pendingStage1 = nil; matchedSaltIndex = nil
        state = .idle
        locationManager.stopUpdatingLocation()
        appendLog("[ble-gps] 已断开")
    }

    private func scan() {
        guard central.state == .poweredOn else { return }
        state = .scanning
        appendLog("[ble-gps] 开始扫描 Nikon Smart Device（服务 UUID 或 Nikon manufacturer data）")
        // Paired cameras may stop advertising the service UUID and expose only
        // Nikon manufacturer data, so foreground reconnect scans cannot use a
        // service-only filter.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func requestLocationAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.canWriteGeo { await self.writeLatestLocationIfAvailable() }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func writeLatestLocationIfAvailable() async {
        guard let location = lastLocation, let characteristic = geoCharacteristic,
              let peripheral, peripheral.state == .connected else { return }
        guard location.horizontalAccuracy >= 0, Date().timeIntervalSince(location.timestamp) < 120 else {
            appendLog("[ble-gps] 跳过过期或无效定位 age=\(Int(Date().timeIntervalSince(location.timestamp)))s accuracy=\(location.horizontalAccuracy)")
            return
        }
        let payload = Self.makeGeoPayload(location: location, date: location.timestamp)
        appendLog("[ble-gps] GEO 写入 bytes=\(payload.count) lat=\(location.coordinate.latitude) lon=\(location.coordinate.longitude)")
        peripheral.writeValue(payload, for: characteristic, type: .withResponse)
    }

    private func handlePairMessage(_ data: Data) {
        guard data.count == 17 else { appendLog("[ble-gps] PAIR 长度异常 bytes=\(data.count)"); return }
        let stage = data[data.startIndex]
        appendLog("[ble-gps] 收到 PAIR stage=\(stage) bytes=17")
        if stage == 2 {
            guard let pairCharacteristic, let peripheral,
                  let stage1 = pendingStage1,
                  let response = Self.makeStage3(stage2: data, stage1: stage1, saltIndex: &matchedSaltIndex)
            else {
                appendLog("[ble-gps] PAIR stage=2 challenge 校验失败，无法生成 stage=3")
                state = .failed("Nikon BLE 配对 challenge 校验失败")
                return
            }
            peripheral.writeValue(response, for: pairCharacteristic, type: .withResponse)
            appendLog("[ble-gps] 已发送 PAIR stage=3 salt=\(matchedSaltIndex ?? -1)")
        } else if stage == 4 {
            didReceiveStage4 = true
            let serial = String(data: data[9..<17], encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? "--"
            appendLog("[ble-gps] 收到 PAIR stage=4 serial=\(serial)，等待 NOT1（最多 3 秒）")
            idWriteTask?.cancel()
            idWriteTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.appendLog("[ble-gps] stage=4 后未收到 NOT1，按协议兼容路径写入控制器名称")
                self.writeControllerID()
            }
        }
    }

    private func writeControllerID() {
        guard !didWriteControllerID, let idCharacteristic, let peripheral else { return }
        didWriteControllerID = true
        idWriteTask?.cancel(); idWriteTask = nil
        var name = Array("ZLinks-iOS".utf8)
        name.append(contentsOf: repeatElement(0, count: max(0, 32 - name.count)))
        peripheral.writeValue(Data(name.prefix(32)), for: idCharacteristic, type: .withResponse)
        appendLog("[ble-gps] 已写入 32 字节控制器名称")
    }

    private func beginPairingIfNeeded() {
        guard pendingStage1 == nil, pairNotificationsEnabled, not1NotificationsEnabled,
              let pairCharacteristic, let peripheral else { return }
        var data = Data([0x01])
        stage1Timestamp = UInt64.random(in: 1...UInt64.max)
        let defaults = UserDefaults.standard
        if let savedDevice = defaults.object(forKey: Self.controllerDeviceKey) as? NSNumber,
           let savedNonce = defaults.object(forKey: Self.controllerNonceKey) as? NSNumber
        {
            stage1Device = savedDevice.uint32Value
            stage1Nonce = savedNonce.uint32Value
            appendLog("[ble-gps] 复用已保存的控制器身份")
        } else {
            stage1Device = (UInt32.random(in: UInt32.min...UInt32.max) & 0xffffff00) | 0x01
            stage1Nonce = UInt32.random(in: UInt32.min...UInt32.max)
            defaults.set(UInt64(stage1Device), forKey: Self.controllerDeviceKey)
            defaults.set(UInt64(stage1Nonce), forKey: Self.controllerNonceKey)
            appendLog("[ble-gps] 已创建并保存全局控制器身份")
        }
        Self.appendLE(stage1Timestamp, to: &data)
        Self.appendLE(stage1Device, to: &data)
        Self.appendLE(stage1Nonce, to: &data)
        pendingStage1 = data
        peripheral.writeValue(data, for: pairCharacteristic, type: .withResponse)
        appendLog("[ble-gps] 已发送 PAIR stage=1")
    }

    private var centralStateName: String {
        switch central.state { case .poweredOn: return "poweredOn"; case .poweredOff: return "poweredOff"; case .unauthorized: return "unauthorized"; case .unsupported: return "unsupported"; case .resetting: return "resetting"; case .unknown: return "unknown" @unknown default: return "unknown" }
    }

    private func appendLog(_ message: String) { logHandler?(message) }

    private var connectionOptions: [String: Any] {
        [
            CBConnectPeripheralOptionEnableTransportBridgingKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ]
    }

    static func makeGeoPayload(location: CLLocation, date: Date) -> Data {
        var bytes = [UInt8](repeating: 0, count: 41)
        bytes[0] = 0x7f; bytes[1] = 0x00
        encodeCoordinate(location.coordinate.latitude, directionPositive: 0x4e, directionNegative: 0x53, into: &bytes, offset: 2)
        encodeCoordinate(location.coordinate.longitude, directionPositive: 0x45, directionNegative: 0x57, into: &bytes, offset: 7)
        let accuracy = location.horizontalAccuracy
        bytes[12] = accuracy <= 5 ? 12 : accuracy <= 10 ? 10 : accuracy <= 25 ? 8 : accuracy <= 50 ? 6 : 4
        let altitude = location.verticalAccuracy >= 0 ? location.altitude : 0
        bytes[13] = altitude < 0 ? 0x4d : 0x50
        let absoluteAltitude = UInt16(min(max(abs(Int(altitude.rounded())), 0), Int(UInt16.max)))
        bytes[14] = UInt8(absoluteAltitude & 0xff); bytes[15] = UInt8(absoluteAltitude >> 8)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(min(max(components.year ?? 1970, 0), Int(UInt16.max)))
        bytes[16] = UInt8(year & 0xff); bytes[17] = UInt8(year >> 8)
        bytes[18] = UInt8(components.month ?? 1); bytes[19] = UInt8(components.day ?? 1)
        bytes[20] = UInt8(components.hour ?? 0); bytes[21] = UInt8(components.minute ?? 0); bytes[22] = UInt8(components.second ?? 0)
        bytes[23] = UInt8((date.timeIntervalSince1970 * 100).rounded().truncatingRemainder(dividingBy: 100))
        bytes[24] = 0x01
        bytes.replaceSubrange(25...30, with: Array("WGS-84".utf8))
        return Data(bytes)
    }

    private static let salts: [(UInt32, UInt32)] = [
        (0x704066e4, 0x0433d552), (0xed4b8fac, 0x15f7e47b),
        (0x24471f11, 0x8b5ea1fc), (0x05960c31, 0x2b8c7f41),
        (0xfda588c1, 0xeba8b1f3), (0x99166056, 0x1bd3d550),
        (0xcd32687f, 0xa9e28a30), (0x2a8fe834, 0xdec7ebf4)
    ]

    private static func makeStage3(stage2: Data, stage1: Data, saltIndex: inout Int?) -> Data? {
        guard stage2.count == 17, stage1.count == 17 else { return nil }
        let cameraTimestamp = readLE64(stage2, at: 1)
        let ourTimestamp = readLE64(stage1, at: 1)
        let cameraDevice = readLE32(stage2, at: 9)
        let cameraNonce = readLE32(stage2, at: 13)
        let camLo = UInt32(cameraTimestamp & 0xffffffff), camHi = UInt32(cameraTimestamp >> 32)
        let ourLo = UInt32(ourTimestamp & 0xffffffff), ourHi = UInt32(ourTimestamp >> 32)
        var matched: Int?
        for (index, salt) in salts.enumerated() {
            let hash = blowfishHash([salt.0, salt.1, camLo.byteSwapped, camHi.byteSwapped, ourLo.byteSwapped, ourHi.byteSwapped])
            if hash.0 == cameraDevice.byteSwapped && hash.1 == cameraNonce.byteSwapped { matched = index; break }
        }
        guard let matched else { return nil }
        saltIndex = matched
        let salt = salts[matched]
        let response = blowfishHash([salt.0, salt.1, ourLo.byteSwapped, ourHi.byteSwapped, camLo.byteSwapped, camHi.byteSwapped])
        var output = Data([0x03])
        appendLE(ourTimestamp, to: &output)
        appendLE(response.0.byteSwapped, to: &output)
        appendLE(response.1.byteSwapped, to: &output)
        return output
    }

    private static func blowfishHash(_ words: [UInt32]) -> (UInt32, UInt32) {
        var left: UInt32 = 0x01020304, right: UInt32 = 0x05060708
        let key: [UInt8] = [0xff, 0xff, 0xaa, 0x55, 0x11, 0x22, 0x33, 0x00]
        for index in stride(from: 0, to: words.count, by: 2) {
            var input = Data(); appendBE(words[index] ^ left, to: &input); appendBE(words[index + 1] ^ right, to: &input)
            var output = [UInt8](repeating: 0, count: 8)
            let outputCount = output.count
            let status = input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmBlowfish), CCOptions(kCCOptionECBMode), key, key.count, nil, inputBytes.baseAddress, input.count, outputBytes.baseAddress, outputCount, nil)
                }
            }
            guard status == kCCSuccess else { return (0, 0) }
            left = readBE(Data(output), at: 0); right = readBE(Data(output), at: 4)
        }
        return (left, right)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    private static func appendBE(_ value: UInt32, to data: inout Data) { var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) } }
    private static func readLE32(_ data: Data, at offset: Int) -> UInt32 { UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24 }
    private static func readLE64(_ data: Data, at offset: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) } }
    private static func readBE(_ data: Data, at offset: Int) -> UInt32 { UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3]) }

    private static func encodeCoordinate(_ value: CLLocationDegrees, directionPositive: UInt8, directionNegative: UInt8, into bytes: inout [UInt8], offset: Int) {
        let absolute = abs(value); let degrees = min(Int(absolute), 255); let minutesFull = (absolute - Double(degrees)) * 60
        let minutes = min(Int(minutesFull), 59); let sub1Full = (minutesFull - Double(minutes)) * 100; let sub1 = min(Int(sub1Full), 99); let sub2 = min(Int((sub1Full - Double(sub1)) * 100), 99)
        bytes[offset] = value < 0 ? directionNegative : directionPositive; bytes[offset + 1] = UInt8(degrees); bytes[offset + 2] = UInt8(minutes); bytes[offset + 3] = UInt8(sub1); bytes[offset + 4] = UInt8(sub2)
    }
}

extension NikonBluetoothGPSService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendLog("[ble-gps] 蓝牙状态=\(self.centralStateName)")
            if central.state == .poweredOn, self.shouldStayConnected {
                if !self.connectToKnownPeripheralIfAvailable() { self.scan() }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor [weak self] in
            guard let self, self.shouldStayConnected, self.state == .scanning, self.peripheral == nil else { return }
            let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            let isNikonManufacturer = manufacturerData.map {
                $0.count >= 2 && $0[$0.startIndex] == 0x99 && $0[$0.startIndex + 1] == 0x03
            } ?? false
            guard serviceUUIDs.contains(Self.serviceUUID) || isNikonManufacturer else { return }
            central.stopScan(); self.peripheral = peripheral; self.cameraName = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.peripheralIdentifierKey)
            self.state = .connecting; self.appendLog("[ble-gps] 发现相机 name=\(self.cameraName ?? "--") rssi=\(RSSI)")
            peripheral.delegate = self
            self.appendLog("[ble-gps] 请求连接并启用 BLE→Classic transport bridging")
            central.connect(peripheral, options: self.connectionOptions)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
            guard let restored else { self.appendLog("[ble-gps] 状态恢复未包含相机"); return }
            self.shouldStayConnected = true
            self.peripheral = restored
            self.cameraName = restored.name
            restored.delegate = self
            self.appendLog("[ble-gps] 系统恢复蓝牙相机 name=\(restored.name ?? "--") state=\(restored.state.rawValue)")
            if restored.state == .connected { restored.discoverServices([Self.serviceUUID]) }
            else { central.connect(restored, options: self.connectionOptions) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor [weak self] in self?.appendLog("[ble-gps] GATT 已连接，开始发现服务"); peripheral.discoverServices([Self.serviceUUID]) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in self?.failAndRetry("GATT 连接失败 error=\(error?.localizedDescription ?? "unknown")", peripheral: peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.failAndRetry("GATT 断开 error=\(error?.localizedDescription ?? "none")", peripheral: peripheral)
        }
    }

    private func failAndRetry(_ message: String, peripheral disconnectedPeripheral: CBPeripheral? = nil) {
        guard shouldStayConnected else { return }
        let wasReady = state == .ready || state == .reconnecting
        appendLog("[ble-gps] \(message)")
        lastError = wasReady ? nil : message
        state = wasReady ? .reconnecting : .failed(message)
        pairCharacteristic = nil; idCharacteristic = nil; geoCharacteristic = nil; not1Characteristic = nil
        pairNotificationsEnabled = false; not1NotificationsEnabled = false
        canWriteGeo = false
        didReceiveStage4 = false; didReceivePairingSuccess = false; didWriteControllerID = false
        idWriteTask?.cancel(); idWriteTask = nil
        pairingConfirmationTask?.cancel(); pairingConfirmationTask = nil
        pendingStage1 = nil; matchedSaltIndex = nil
        if !wasReady { peripheral = nil }
        reconnectTask?.cancel(); reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.shouldStayConnected else { return }
            if wasReady, let disconnectedPeripheral {
                self.peripheral = disconnectedPeripheral
                self.state = .reconnecting
                self.appendLog("[ble-gps] 尝试恢复已知相机连接")
                self.central.connect(disconnectedPeripheral, options: self.connectionOptions)
            } else {
                self.peripheral = nil
                self.scan()
            }
        }
    }
}

extension NikonBluetoothGPSService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }; if let error { self.failAndRetry("服务发现失败 error=\(error.localizedDescription)"); return }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { self.failAndRetry("未找到 Nikon Smart Device 服务"); return }
            peripheral.discoverCharacteristics([Self.pairUUID, Self.idUUID, Self.geoUUID, Self.not1UUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }; if let error { self.failAndRetry("特征发现失败 error=\(error.localizedDescription)"); return }
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid { case Self.pairUUID: self.pairCharacteristic = characteristic; peripheral.setNotifyValue(true, for: characteristic); case Self.idUUID: self.idCharacteristic = characteristic; case Self.geoUUID: self.geoCharacteristic = characteristic; case Self.not1UUID: self.not1Characteristic = characteristic; peripheral.setNotifyValue(true, for: characteristic); default: break }
            }
            guard self.pairCharacteristic != nil, self.geoCharacteristic != nil else { self.failAndRetry("缺少 PAIR/GEO 特征"); return }
            self.state = .pairing; self.appendLog("[ble-gps] 特征已发现；如相机要求首次配对，将等待 PAIR challenge")
            self.startSyncLoop()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }; if let error { self.appendLog("[ble-gps] 特征读取失败 uuid=\(characteristic.uuid) error=\(error.localizedDescription)"); return }
            guard let data = characteristic.value else { return }
            if characteristic.uuid == Self.pairUUID { self.handlePairMessage(data) }
            else if characteristic.uuid == Self.not1UUID, data == Data([0x01, 0x00]) {
                self.appendLog("[ble-gps] NOT1=01 00，BLE 握手已被相机接受")
                self.didReceivePairingSuccess = true
                self.pairingConfirmationTask?.cancel(); self.pairingConfirmationTask = nil
                if self.didReceiveStage4 { self.writeControllerID() }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error { self.appendLog("[ble-gps] 订阅失败 uuid=\(characteristic.uuid) error=\(error.localizedDescription)"); return }
            if characteristic.uuid == Self.pairUUID { self.pairNotificationsEnabled = characteristic.isNotifying }
            if characteristic.uuid == Self.not1UUID { self.not1NotificationsEnabled = characteristic.isNotifying }
            self.appendLog("[ble-gps] 订阅状态 uuid=\(characteristic.uuid) active=\(characteristic.isNotifying)")
            self.beginPairingIfNeeded()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.appendLog("[ble-gps] 写入失败 uuid=\(characteristic.uuid) error=\(error.localizedDescription)")
                if characteristic.uuid == Self.geoUUID { self.lastError = "相机拒绝 GPS：\(error.localizedDescription)"; self.state = .failed(self.lastError!) }
                return
            }
            self.appendLog("[ble-gps] 写入成功 uuid=\(characteristic.uuid)")
            if characteristic.uuid == Self.idUUID {
                self.canWriteGeo = true
                self.state = .pairing
                self.appendLog("[ble-gps] 控制器名称写入完成；系统正在尝试 Classic transport bridging，等待 NOT1")
                await self.writeLatestLocationIfAvailable()
                self.pairingConfirmationTask?.cancel()
                self.pairingConfirmationTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, !Task.isCancelled, !self.didReceivePairingSuccess else { return }
                    self.canWriteGeo = false
                    self.lastError = "相机未确认蓝牙配对。iOS transport bridging 未能完成 Nikon Classic bond。"
                    self.state = .failed(self.lastError!)
                    self.appendLog("[ble-gps] 等待 NOT1 超时；BLE GATT 可写不代表 Nikon Classic bond 已完成")
                }
            }
            if characteristic.uuid == Self.geoUUID {
                self.lastSyncDate = Date()
                if self.didReceivePairingSuccess {
                    self.lastError = nil
                    self.state = .ready
                } else {
                    self.appendLog("[ble-gps] GEO 的 GATT 写入已确认，但尚无 NOT1；不判定相机配对成功")
                }
            }
        }
    }
}

extension NikonBluetoothGPSService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.appendLog("[ble-gps] 定位授权状态=\(manager.authorizationStatus.rawValue)")
            if manager.authorizationStatus == .authorizedWhenInUse { self.requestLocationAuthorization() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastLocation = locations.last(where: { $0.horizontalAccuracy >= 0 })
            if self.canWriteGeo { await self.writeLatestLocationIfAvailable() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.appendLog("[ble-gps] 定位失败 error=\(error.localizedDescription)") }
    }
}
