import Foundation
import Combine
import CryptoKit
import Security
@preconcurrency import CoreBluetooth

enum ConnectionPhase: String {
    case idle, scanning, connecting, initializing, ready, disconnecting, failed
}

struct SwordDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

struct LightstickSessionGate {
    private(set) var generation: UInt64 = 0
    private(set) var activeID: UUID?
    private(set) var isReleasing = false
    var canBegin: Bool { activeID == nil }

    mutating func begin(_ id: UUID) -> UInt64? {
        guard canBegin else { return nil }
        generation &+= 1
        activeID = id
        isReleasing = false
        return generation
    }

    mutating func beginRelease() {
        generation &+= 1
        isReleasing = activeID != nil
    }

    func accepts(_ id: UUID, generation token: UInt64? = nil) -> Bool {
        activeID == id && !isReleasing && (token == nil || token == generation)
    }

    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        invalidate()
        return true
    }

    mutating func invalidate() {
        activeID = nil
        isReleasing = false
        generation &+= 1
    }
}

struct LatestLightQueue {
    struct Submission: Equatable {
        let sequence: UInt32
        let color: LightRGB
    }

    private(set) var pending: LightRGB?
    private(set) var sequenceExhausted = false
    private var nextSequence: UInt32
    private var lastSentAt: TimeInterval?
    let minimumInterval: TimeInterval = 0.2

    init(nextSequence: UInt32 = 1) { self.nextSequence = nextSequence }
    var hasPending: Bool { pending != nil }
    mutating func offer(_ color: LightRGB) { pending = color }
    mutating func removePending() { pending = nil }
    mutating func reset() { self = LatestLightQueue() }

    func delay(at now: TimeInterval) -> TimeInterval {
        guard let lastSentAt else { return 0 }
        return max(0, minimumInterval - (now - lastSentAt))
    }

    mutating func take(at now: TimeInterval, capacityAvailable: Bool) -> Submission? {
        guard now.isFinite, capacityAvailable, !sequenceExhausted,
              delay(at: now) <= 0, let color = pending else { return nil }
        let value = Submission(sequence: nextSequence, color: color)
        pending = nil
        lastSentAt = now
        if nextSequence == UInt32.max { sequenceExhausted = true }
        else { nextSequence += 1 }
        return value
    }
}

struct LightstickDevicePolicy {
    let expectedMACHash: String

    static func hashMAC(_ displayMAC: String) -> String {
        SHA256.hash(data: Data(displayMAC.uppercased().utf8))
            .map { String(format: "%02x", Int($0)) }.joined()
    }

    var isConfigured: Bool {
        expectedMACHash.count == 64 && expectedMACHash.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    func accepts(name: String, mac: String, firmware: String) -> Bool {
        isConfigured && name.uppercased().hasPrefix("LT") && firmware == "v0.20.14"
            && Self.hashMAC(mac) == expectedMACHash.lowercased()
    }
}

struct LightstickResponseWindow {
    private(set) var attempts = 0
    private var deadline: TimeInterval?

    mutating func start(at now: TimeInterval) {
        attempts = 0
        deadline = now.isFinite ? now + 6 : nil
    }

    func isOpen(at now: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return now.isFinite && now < deadline
    }

    func canScheduleRead(at now: TimeInterval) -> Bool {
        isOpen(at: now + 0.6) && attempts < 3
    }

    mutating func beginRead(at now: TimeInterval) -> TimeInterval? {
        guard isOpen(at: now), attempts < 3, let deadline else { return nil }
        attempts += 1
        return min(5, deadline - now)
    }
}

struct LightstickRhythmIntent: Codable {
    private(set) var selectedID: UUID?
    private(set) var selectedName = ""
    private(set) var rhythmRequested = false
    private(set) var backgroundEnabled = false
    private(set) var startedAt: Date?
    private(set) var retryAttempt = 0
    private(set) var generation: UInt64 = 0
    static let restorationLifetime: TimeInterval = 6 * 60 * 60

    var keepsBackgroundConnection: Bool { rhythmRequested && backgroundEnabled }

    mutating func select(_ id: UUID, name: String) {
        selectedID = id
        selectedName = name
        retryAttempt = 0
        generation &+= 1
    }

    mutating func start(at date: Date) {
        guard !rhythmRequested else { return }
        rhythmRequested = true
        startedAt = date
        retryAttempt = 0
        generation &+= 1
    }

    mutating func setBackgroundEnabled(_ enabled: Bool) {
        guard backgroundEnabled != enabled else { return }
        backgroundEnabled = enabled
        generation &+= 1
    }

    mutating func stop(clearSelection: Bool = false) {
        rhythmRequested = false
        startedAt = nil
        retryAttempt = 0
        generation &+= 1
        if clearSelection { selectedID = nil; selectedName = "" }
    }

    func permitsRecovery(inBackground: Bool) -> Bool {
        rhythmRequested && selectedID != nil && selectedName.uppercased().hasPrefix("LT")
            && (!inBackground || backgroundEnabled)
    }

    func permitsRestoration(at date: Date) -> Bool {
        guard permitsRecovery(inBackground: true), (0..<4).contains(retryAttempt), let startedAt else { return false }
        let age = date.timeIntervalSince(startedAt)
        return age.isFinite && age >= 0 && age < Self.restorationLifetime
    }

    mutating func nextRetryDelay(inBackground: Bool) -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4, 8]
        guard permitsRecovery(inBackground: inBackground), delays.indices.contains(retryAttempt) else { return nil }
        let delay = delays[retryAttempt]
        retryAttempt += 1
        return delay
    }
}

@MainActor
final class LightstickManager: NSObject, ObservableObject {
    static let restorationIdentifier = "com.magiicccc.wanshoujian.rhythm.central.v1"
    private static let restorationIntentKey = "lightstick.background-rhythm-intent.v1"
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var devices: [SwordDevice] = []
    @Published private(set) var deviceName = ""
    @Published private(set) var firmware = ""
    @Published private(set) var mac = ""
    @Published private(set) var message = "选择宝宝剑后，可手动验证颜色与亮度。"
    @Published private(set) var lastSubmitted = ""
    @Published private(set) var isSending = false
    @Published private(set) var lastRhythmColor: LightRGB?
    @Published private(set) var isRestoringSession = false
    @Published var colorHex = "#00FF00"
    @Published var brightness: Double = 0.25

    var canControl: Bool { phase == .ready && !gate.isReleasing && (!backgrounded || rhythmIntent.keepsBackgroundConnection) }
    var hasCreatedCentralManager: Bool { central != nil }
    private var canDrain: Bool { canControl || (finalBlackPending && phase == .ready && !gate.isReleasing) }

    private enum Step: Equatable {
        case none, connecting, services, characteristics, mac, compatibility, firmware
        case beforeChallenge, challengeWrite, beforeSignature, signature, complete
    }
    private enum ConnectionOrigin: Equatable { case manual, reconnect, restored }

    private let preview: Bool
    private let policy: LightstickDevicePolicy
    private let preferences: UserDefaults
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var services: [CBUUID: CBService] = [:]
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingServices: Set<CBUUID> = []
    private var expectedRead: CBCharacteristic?
    private var expectedWrite: CBCharacteristic?
    private var macBytes = Data()
    private var gate = LightstickSessionGate()
    private var queue = LatestLightQueue()
    private var step: Step = .none
    private var connectionOrigin: ConnectionOrigin = .manual
    private var wantsScan = false
    private var backgrounded = false
    private var rhythmIntent = LightstickRhythmIntent()
    private var finalBlackPending = false
    private var disconnectAfterDrain = false
    private var wantsReconnect = false
    private var pendingRestored: [CBPeripheral] = []
    private var discardedRestoredIDs: Set<UUID> = []
    private var restoredStatePending = false
    private var recoveryExhausted = false
    private var scanGeneration: UInt64 = 0
    private var responseWindow = LightstickResponseWindow()
    private var releaseDestination: ConnectionPhase = .idle
    private var releaseMessage = "连接已断开。"
    private var scanTask: Task<Void, Never>?
    private var stageTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var sendWaitTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectPowerTask: Task<Void, Never>?
    private var finalDisconnectTask: Task<Void, Never>?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var requiredServices: [CBUUID] {
        [CBUUID(string: LightstickProtocol.lightingService), CBUUID(string: LightstickProtocol.compatibilityService)]
    }
    private var requiredEndpoints: [(String, String)] {
        [
            (LightstickProtocol.colorWrite, LightstickProtocol.lightingService),
            (LightstickProtocol.challengeWrite, LightstickProtocol.compatibilityService),
            (LightstickProtocol.challengeResponseRead, LightstickProtocol.compatibilityService),
            (LightstickProtocol.macRead, LightstickProtocol.compatibilityService),
            (LightstickProtocol.firmwareRead, LightstickProtocol.compatibilityService),
        ]
    }

    init(preview: Bool = false, expectedMACHash: String? = nil, preferences: UserDefaults = .standard) {
        self.preview = preview
        self.preferences = preferences
        let configured = expectedMACHash ?? Bundle.main.object(forInfoDictionaryKey: "KnownDeviceMACSHA256") as? String ?? ""
        policy = LightstickDevicePolicy(expectedMACHash: configured.trimmingCharacters(in: .whitespacesAndNewlines))
        super.init()
        if preview {
            phase = .ready
            deviceName = "灯效预览"
            message = "屏幕演示已就绪，可调整颜色与亮度。"
        }
    }

    func scan() {
        backgrounded = false
        guard !preview else {
            phase = .ready
            message = "当前为屏幕演示，可直接调整灯效。"
            return
        }
        guard gate.canBegin, pendingRestored.isEmpty, discardedRestoredIDs.isEmpty else {
            message = "请先断开当前连接，并等待系统完成释放。"
            return
        }
        cancelRhythmIntent(clearSelection: true)
        wantsScan = true
        if central == nil {
            waitForCentralState()
            createCentral()
        } else if let central { handleCentralState(central) }
    }

    private func waitForCentralState() {
        stopScan()
        wantsScan = true
        phase = .scanning
        message = "正在等待蓝牙授权与系统状态。"
        let token = scanGeneration
        scanTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self, token == self.scanGeneration, self.wantsScan else { return }
            self.stopScan()
            self.phase = .failed
            self.message = "蓝牙状态等待超时，可完成系统授权后重新扫描。"
        }
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn, gate.canBegin, !backgrounded else { return }
        stopScan()
        wantsScan = true
        devices = []
        discovered = [:]
        phase = .scanning
        message = "正在寻找附近的宝宝剑，请保持设备处于配对状态。"
        central.scanForPeripherals(withServices: [CBUUID(string: LightstickProtocol.lightingService)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        let token = scanGeneration
        scanTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            guard let self, token == self.scanGeneration, self.phase == .scanning else { return }
            self.stopScan()
            self.phase = .idle
            self.message = self.devices.isEmpty ? "可开启宝宝剑的配对模式后重新扫描。" : "请选择列表中的宝宝剑。"
        }
    }

    private func stopScan() {
        scanGeneration &+= 1
        scanTask?.cancel(); scanTask = nil
        wantsScan = false
        if central?.state == .poweredOn && central?.isScanning == true { central?.stopScan() }
    }

    func connect(_ id: UUID) {
        guard !preview else { phase = .ready; message = "屏幕演示已就绪。"; return }
        guard !backgrounded, gate.canBegin, pendingRestored.isEmpty, discardedRestoredIDs.isEmpty else {
            message = "请等待当前会话释放后再连接。"
            return
        }
        guard let central, central.state == .poweredOn,
              let selected = devices.first(where: { $0.id == id }),
              selected.name.uppercased().hasPrefix("LT"), let candidate = discovered[id] else {
            message = "请先扫描并选择列表中的宝宝剑。"
            return
        }
        stopScan()
        cancelRecoveryTasks()
        rhythmIntent.select(id, name: selected.name)
        recoveryExhausted = false
        persistRhythmIntent()
        beginConnection(candidate, name: selected.name)
    }

    private func beginConnection(_ candidate: CBPeripheral, name: String, origin: ConnectionOrigin = .manual) {
        guard let central, central.state == .poweredOn, gate.begin(candidate.identifier) != nil else { return }
        cancelRecoveryTasks()
        stopScan()
        peripheral = candidate
        connectionOrigin = origin
        candidate.delegate = self
        deviceName = name
        firmware = ""; mac = ""; macBytes = Data(); lastSubmitted = ""
        lastRhythmColor = nil
        services = [:]; characteristics = [:]; pendingServices = []
        queue.reset(); isSending = false
        phase = .connecting; step = .connecting
        message = "正在连接 \(name)。"
        armStageTimeout(12, message: "连接等待超时，请检查宝宝剑配对状态")
        switch candidate.state {
        case .connected: handleConnected(candidate)
        case .connecting: break
        case .disconnected: central.connect(candidate, options: nil)
        case .disconnecting: startDisconnect(destination: .idle, message: "正在结束旧连接以重新校验设备。")
        @unknown default: fail("请重新连接以读取设备状态")
        }
    }

    func disconnect() {
        cancelRhythmIntent(clearSelection: true)
        startDisconnect(destination: .idle, message: "连接已断开。")
    }

    func setBackgroundRhythmEnabled(_ enabled: Bool) {
        if backgrounded && !enabled { endRhythm(sendBlack: true) }
        rhythmIntent.setBackgroundEnabled(enabled)
        cancelRecoveryTasks()
        persistRhythmIntent()
        if backgrounded && !rhythmIntent.keepsBackgroundConnection && !finalBlackPending
            && finalDisconnectTask == nil && phase != .disconnecting {
            startDisconnect(destination: .idle, message: "后台律动已关闭。")
        } else if gate.canBegin { scheduleReconnect() }
    }

    func applicationDidEnterBackground() {
        backgrounded = true
        stopScan()
        devices = []
        discovered = [:]
        if rhythmIntent.keepsBackgroundConnection {
            if gate.canBegin { scheduleReconnect() }
            else {
                message = isRestoringSession ? "正在恢复设备会话，音乐律动可在前台重新开始。"
                    : "后台律动已启用，将继续跟随当前音频。"
            }
        } else {
            cancelRhythmIntent()
            if finalBlackPending && phase == .ready {
                disconnectAfterDrain = true
                drain()
            } else if finalDisconnectTask == nil {
                startDisconnect(destination: .idle, message: "手动控制已暂停，返回后可重新扫描。")
            }
        }
    }

    func applicationWillEnterForeground() {
        backgrounded = false
        finalDisconnectTask?.cancel(); finalDisconnectTask = nil
        if gate.canBegin { scheduleReconnect() }
        if isRestoringSession {
            message = phase == .ready ? "设备会话已恢复，音乐律动可在前台重新开始。"
                : "设备会话正在恢复，音乐律动可在前台重新开始。"
        }
    }

    func pauseForBackground() { applicationDidEnterBackground() }

    func submitRhythmColor(_ color: LightRGB) {
        guard !backgrounded || rhythmIntent.backgroundEnabled else { return }
        let wasRequested = rhythmIntent.rhythmRequested
        rhythmIntent.start(at: Date())
        if !wasRequested {
            recoveryExhausted = false
            clearPendingColors()
            persistRhythmIntent()
        }
        if preview && !backgrounded && phase == .idle { phase = .ready }
        isRestoringSession = false
        if canControl { enqueue(color) }
        else if gate.canBegin { scheduleReconnect() }
    }

    func endRhythm(sendBlack: Bool) {
        let maySendBlack = sendBlack && canDrain
        let cancelInitialization = connectionOrigin != .manual && phase != .ready && !gate.canBegin
        cancelRhythmIntent()
        clearPendingColors()
        disconnectAfterDrain = backgrounded && maySendBlack
        finalBlackPending = maySendBlack
        if maySendBlack { enqueue(LightRGB(red: 0, green: 0, blue: 0)) }
        else if backgrounded || cancelInitialization { startDisconnect(destination: .idle, message: "音乐律动已停止。") }
    }

    private func cancelRhythmIntent(clearSelection: Bool = false) {
        cancelRecoveryTasks()
        rhythmIntent.stop(clearSelection: clearSelection)
        recoveryExhausted = false
        lastRhythmColor = nil
        isRestoringSession = false
        persistRhythmIntent()
    }

    private func clearPendingColors() {
        drainTask?.cancel(); drainTask = nil
        sendWaitTask?.cancel(); sendWaitTask = nil
        finalDisconnectTask?.cancel(); finalDisconnectTask = nil
        queue.removePending()
        isSending = false
        finalBlackPending = false
        disconnectAfterDrain = false
    }

    private func persistRhythmIntent() {
        guard !preview else { return }
        if rhythmIntent.permitsRestoration(at: Date()), let data = try? JSONEncoder().encode(rhythmIntent) {
            preferences.set(data, forKey: Self.restorationIntentKey)
        } else { preferences.removeObject(forKey: Self.restorationIntentKey) }
    }

    private func createCentral() {
        guard !preview, central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier])
    }

    func restoreIfRequested(identifiers: [String]) {
        guard !preview, identifiers.contains(Self.restorationIdentifier), central == nil, gate.canBegin else { return }
        if let data = preferences.data(forKey: Self.restorationIntentKey),
           let saved = try? JSONDecoder().decode(LightstickRhythmIntent.self, from: data),
           saved.permitsRestoration(at: Date()) {
            rhythmIntent = saved
            isRestoringSession = true
            backgrounded = true
            message = "正在恢复已启用的后台设备会话，并重新核对宝宝剑。"
        } else {
            preferences.removeObject(forKey: Self.restorationIntentKey)
            message = "旧后台会话已结束，可在前台重新选择设备。"
        }
        // System restoration launches use the original identifier, even when old intent now requires cancellation.
        createCentral()
    }

    private func cancelRecoveryTasks() {
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectPowerTask?.cancel(); reconnectPowerTask = nil
        wantsReconnect = false
    }

    private func scheduleReconnect() {
        guard !preview, gate.canBegin, pendingRestored.isEmpty, discardedRestoredIDs.isEmpty,
              reconnectTask == nil, !wantsReconnect, !wantsScan, !recoveryExhausted,
              rhythmIntent.permitsRecovery(inBackground: backgrounded) else { return }
        guard let delay = rhythmIntent.nextRetryDelay(inBackground: backgrounded) else {
            recoveryExhausted = true
            message = "本轮自动重连已结束，可在前台重新选择宝宝剑。"
            preferences.removeObject(forKey: Self.restorationIntentKey)
            return
        }
        persistRhythmIntent()
        let token = rhythmIntent.generation
        message = "宝宝剑暂时离线，将在 \(Int(delay)) 秒后重连已选设备。"
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, token == self.rhythmIntent.generation, self.gate.canBegin,
                  self.rhythmIntent.permitsRecovery(inBackground: self.backgrounded) else { return }
            self.reconnectTask = nil
            self.wantsReconnect = true
            if self.central == nil { self.createCentral() }
            if self.central?.state == .poweredOn { self.connectSelectedPeripheral() }
            else { self.waitForReconnectPower() }
        }
    }

    private func waitForReconnectPower() {
        reconnectPowerTask?.cancel()
        let token = rhythmIntent.generation
        reconnectPowerTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, token == self.rhythmIntent.generation, self.wantsReconnect else { return }
            self.reconnectPowerTask = nil
            self.wantsReconnect = false
            self.scheduleReconnect()
        }
    }

    private func connectSelectedPeripheral() {
        guard let central, central.state == .poweredOn, gate.canBegin, wantsReconnect,
              let id = rhythmIntent.selectedID, rhythmIntent.permitsRecovery(inBackground: backgrounded) else { return }
        reconnectPowerTask?.cancel(); reconnectPowerTask = nil
        wantsReconnect = false
        guard let candidate = central.retrievePeripherals(withIdentifiers: [id]).first(where: { $0.identifier == id }) else {
            scheduleReconnect()
            return
        }
        beginConnection(candidate, name: rhythmIntent.selectedName, origin: .reconnect)
    }

    private func processRestoredPeripherals() {
        guard let central, central.state == .poweredOn, !pendingRestored.isEmpty else { return }
        stopScan()
        let values = pendingRestored
        pendingRestored = []
        let selected = rhythmIntent.permitsRecovery(inBackground: backgrounded) ? rhythmIntent.selectedID : nil
        var candidate: CBPeripheral?
        var handled: Set<UUID> = []
        for value in values {
            guard handled.insert(value.identifier).inserted else { continue }
            if value.identifier == selected && candidate == nil { candidate = value }
            else if value.state != .disconnected {
                discardedRestoredIDs.insert(value.identifier)
                value.delegate = nil
                central.cancelPeripheralConnection(value)
            }
        }
        if let candidate, gate.canBegin {
            // Always rediscover and repeat MAC, firmware and challenge reads; cached characteristics stay unused.
            beginConnection(candidate, name: rhythmIntent.selectedName, origin: .restored)
        } else if discardedRestoredIDs.isEmpty {
            if !rhythmIntent.rhythmRequested { phase = .idle }
            scheduleReconnect()
        } else if gate.canBegin {
            phase = .disconnecting
            message = "正在释放已结束的后台设备会话。"
        }
    }

    func applyColor(_ hex: String) {
        guard let color = LightRGB.parse(hex: hex) else {
            message = "请输入 #RRGGBB 格式的颜色。"
            return
        }
        colorHex = color.hex
        if canControl && !rhythmIntent.rhythmRequested { sendCurrent() }
    }

    func applyBrightness(_ value: Double) {
        guard value.isFinite else { message = "请选择有效的亮度。"; return }
        brightness = min(1, max(0, value))
        if canControl && !rhythmIntent.rhythmRequested { sendCurrent() }
    }

    func sendCurrent() {
        guard canControl else { message = "连接就绪后即可发送颜色。"; return }
        guard brightness.isFinite, let color = LightRGB.parse(hex: colorHex) else {
            message = "请检查颜色格式与亮度数值。"
            return
        }
        enqueue(color.scaled(brightness: brightness))
    }

    func turnOff() {
        guard canControl else { return }
        brightness = 0
        enqueue(LightRGB(red: 0, green: 0, blue: 0))
    }

    private func enqueue(_ color: LightRGB) {
        if preview {
            lastSubmitted = color.hex
            message = "屏幕预览：\(color.hex)。"
            if rhythmIntent.rhythmRequested || finalBlackPending { lastRhythmColor = color }
            finalBlackPending = false
            if disconnectAfterDrain {
                disconnectAfterDrain = false
                startDisconnect(destination: .idle, message: "音乐律动已停止。")
            }
            return
        }
        queue.offer(color)
        isSending = true
        drain()
    }

    private func drain() {
        guard canDrain, queue.hasPending, let peripheral,
              let writer = characteristic(LightstickProtocol.colorWrite) else { return }
        if queue.sequenceExhausted { fail("本轮序号已用完，请重新连接"); return }
        guard peripheral.canSendWriteWithoutResponse else {
            if sendWaitTask == nil {
                let token = gate.generation
                sendWaitTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard let self, self.gate.generation == token, self.queue.hasPending else { return }
                    self.fail("蓝牙发送队列等待超时，请重新连接")
                }
            }
            return
        }
        sendWaitTask?.cancel(); sendWaitTask = nil
        let delay = queue.delay(at: now)
        if delay > 0 {
            guard drainTask == nil else { return }
            let token = gate.generation
            drainTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard let self, self.gate.generation == token else { return }
                self.drainTask = nil
                self.drain()
            }
            return
        }
        guard let submission = queue.take(at: now, capacityAvailable: true) else { return }
        let packet = LightstickProtocol.solid(sequence: submission.sequence, rgb: submission.color)
        guard packet.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            fail("当前控色报文超过单包传输容量")
            return
        }
        peripheral.writeValue(packet, for: writer, type: .withoutResponse)
        if rhythmIntent.rhythmRequested || finalBlackPending { lastRhythmColor = submission.color }
        finalBlackPending = false
        lastSubmitted = submission.color.hex
        if !rhythmIntent.rhythmRequested { message = "已提交 \(submission.color.hex)，请观察宝宝剑的实际颜色。" }
        isSending = queue.hasPending
        if disconnectAfterDrain {
            disconnectAfterDrain = false
            let token = gate.generation
            // Without-response writes have no delivery callback; allow a short transmit grace before local cancellation.
            finalDisconnectTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard let self, self.gate.generation == token, !self.rhythmIntent.rhythmRequested else { return }
                self.finalDisconnectTask = nil
                self.startDisconnect(destination: .idle, message: "音乐律动已停止。")
            }
        }
    }

    private func characteristic(_ uuid: String) -> CBCharacteristic? { characteristics[CBUUID(string: uuid)] }

    private func accepts(_ value: CBPeripheral) -> Bool {
        peripheral === value && gate.accepts(value.identifier)
    }

    private func read(_ uuid: String, as nextStep: Step, timeout: TimeInterval = 5) {
        guard let peripheral, accepts(peripheral), let value = characteristic(uuid) else {
            fail("必要设备特征尚未就绪")
            return
        }
        step = nextStep
        expectedRead = value
        armStageTimeout(timeout, message: "读取设备等待超时，请重新连接")
        peripheral.readValue(for: value)
    }

    private func armStageTimeout(_ seconds: TimeInterval, message: String) {
        stageTask?.cancel()
        let token = gate.generation
        stageTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, self.gate.generation == token, !self.gate.isReleasing else { return }
            self.fail(message)
        }
    }

    private func scheduleHandshake(after seconds: TimeInterval, step expected: Step, action: @escaping @MainActor () -> Void) {
        handshakeTask?.cancel()
        step = expected
        let token = gate.generation
        handshakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, self.gate.generation == token, self.step == expected, !self.gate.isReleasing else { return }
            action()
        }
    }

    private func sendChallenge() {
        guard let peripheral, accepts(peripheral), let writer = characteristic(LightstickProtocol.challengeWrite) else { return }
        var nonce = Data(count: 16)
        let status = nonce.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
        }
        guard status == errSecSuccess else { fail("安全随机数暂时不可用，请重新连接"); return }
        do {
            let packet = try LightstickProtocol.challenge(mac: macBytes, nonce: nonce)
            guard packet.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                fail("设备确认请求需要完整的 39 字节单包")
                return
            }
            step = .challengeWrite
            expectedWrite = writer
            armStageTimeout(5, message: "设备确认请求等待超时")
            peripheral.writeValue(packet, for: writer, type: .withResponse)
        } catch { fail(error.localizedDescription) }
    }

    private func scheduleSignatureRead() {
        guard responseWindow.canScheduleRead(at: now) else {
            fail("设备响应结构尚未就绪，请重新连接")
            return
        }
        scheduleHandshake(after: 0.6, step: .beforeSignature) { [weak self] in
            guard let self else { return }
            guard let timeout = self.responseWindow.beginRead(at: self.now) else {
                self.fail("设备响应等待窗口已结束，请重新连接")
                return
            }
            self.read(LightstickProtocol.challengeResponseRead, as: .signature, timeout: timeout)
        }
    }

    private func fail(_ reason: String, allowRecovery: Bool = true) {
        if !allowRecovery { cancelRhythmIntent(clearSelection: true) }
        startDisconnect(destination: .failed, message: reason)
    }

    private func cancelSessionTasks() {
        stageTask?.cancel(); stageTask = nil
        handshakeTask?.cancel(); handshakeTask = nil
        drainTask?.cancel(); drainTask = nil
        sendWaitTask?.cancel(); sendWaitTask = nil
        finalDisconnectTask?.cancel(); finalDisconnectTask = nil
        expectedRead = nil; expectedWrite = nil
        responseWindow = LightstickResponseWindow()
        queue.reset(); isSending = false
        lastRhythmColor = nil
        finalBlackPending = false; disconnectAfterDrain = false
    }

    private func startDisconnect(destination: ConnectionPhase, message reason: String) {
        stopScan()
        cancelSessionTasks()
        if preview { phase = .idle; message = reason; return }
        guard let peripheral, gate.activeID == peripheral.identifier else {
            phase = destination; message = reason
            scheduleReconnect()
            return
        }
        if gate.isReleasing { return }
        gate.beginRelease()
        releaseDestination = destination; releaseMessage = reason
        phase = .disconnecting; step = .none
        message = "\(reason) 正在等待系统释放连接。"
        if central?.state == .poweredOn { central?.cancelPeripheralConnection(peripheral) }
        let token = gate.generation
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, self.gate.generation == token, self.gate.isReleasing else { return }
            self.message = "系统仍在释放连接。可将宝宝剑关机再开机，并等待状态恢复。"
        }
    }

    private func finishConnection(_ value: CBPeripheral, failed: Bool, error: Error?) {
        if discardedRestoredIDs.remove(value.identifier) != nil {
            if discardedRestoredIDs.isEmpty {
                if gate.canBegin && !rhythmIntent.rhythmRequested {
                    phase = .idle
                    message = "旧设备会话已释放，可重新扫描宝宝剑。"
                }
                scheduleReconnect()
            }
            return
        }
        guard gate.activeID == value.identifier else { return }
        let wasReleasing = gate.isReleasing
        cancelSessionTasks()
        releaseTask?.cancel(); releaseTask = nil
        value.delegate = nil
        gate.finish(value.identifier)
        peripheral = nil; services = [:]; characteristics = [:]; pendingServices = []
        step = .none
        if wasReleasing { phase = releaseDestination; message = releaseMessage }
        else {
            phase = failed || error != nil ? .failed : .idle
            message = failed ? "连接未完成，请确认宝宝剑处于配对状态。" : "宝宝剑连接已断开，可重新扫描连接。"
        }
        scheduleReconnect()
    }

    private func invalidateCentralSession(_ reason: String) {
        // CoreBluetooth declares sessions disconnected below poweredOn; a fresh central isolates old callbacks.
        stopScan()
        cancelSessionTasks()
        cancelRecoveryTasks()
        releaseTask?.cancel(); releaseTask = nil
        peripheral?.delegate = nil
        central?.delegate = nil
        central = nil; peripheral = nil
        services = [:]; characteristics = [:]; pendingServices = []
        discovered = [:]; devices = []
        pendingRestored = []; discardedRestoredIDs = []; restoredStatePending = false
        gate.invalidate()
        step = .none
        phase = .failed
        message = reason
        scheduleReconnect()
    }

    private func handleCentralState(_ value: CBCentralManager) {
        guard central === value, !preview else { return }
        if value.state == .poweredOn {
            if restoredStatePending {
                restoredStatePending = false
                stopScan()
                if pendingRestored.isEmpty && !rhythmIntent.rhythmRequested && gate.canBegin { phase = .idle }
            }
            processRestoredPeripherals()
            if wantsReconnect { connectSelectedPeripheral() }
            else if isRestoringSession && gate.canBegin { scheduleReconnect() }
            if wantsScan && gate.canBegin && !backgrounded { beginScan() }
            return
        }
        let reason: String
        switch value.state {
        case .unauthorized:
            cancelRhythmIntent()
            reason = "请在系统设置中允许本 App 使用蓝牙。"
        case .poweredOff: reason = "请开启系统蓝牙后重新扫描。"
        case .unsupported:
            cancelRhythmIntent()
            reason = "当前设备的蓝牙功能不支持本次连接。"
        case .unknown, .resetting:
            if gate.canBegin && discovered.isEmpty {
                if wantsReconnect || !pendingRestored.isEmpty { return }
                if wantsScan && scanTask == nil { waitForCentralState() }
                message = "正在等待系统蓝牙状态。"
                return
            }
            reason = "系统蓝牙正在恢复，请稍后重新连接。"
        case .poweredOn: return
        @unknown default: reason = "请检查系统蓝牙状态后重新扫描。"
        }
        invalidateCentralSession(reason)
    }

    private func handleConnected(_ value: CBPeripheral) {
        guard accepts(value) else {
            central?.cancelPeripheralConnection(value)
            return
        }
        guard phase == .connecting else { return }
        phase = .initializing; step = .services
        message = "正在读取宝宝剑的设备信息。"
        armStageTimeout(5, message: "读取设备服务等待超时")
        value.discoverServices(requiredServices)
    }

    private func handleServices(_ value: CBPeripheral, error: Error?) {
        guard accepts(value), step == .services else { return }
        guard error == nil else { fail("设备服务读取失败，请重新连接"); return }
        services = [:]
        for service in value.services ?? [] where requiredServices.contains(service.uuid) { services[service.uuid] = service }
        guard requiredServices.allSatisfy({ services[$0] != nil }) else { fail("必要设备服务尚未就绪"); return }
        step = .characteristics
        pendingServices = Set(requiredServices)
        armStageTimeout(5, message: "读取设备特征等待超时")
        for service in services.values { value.discoverCharacteristics(nil, for: service) }
    }

    private func handleCharacteristics(_ value: CBPeripheral, service: CBService, error: Error?) {
        guard accepts(value), step == .characteristics, services[service.uuid] === service,
              pendingServices.contains(service.uuid) else { return }
        guard error == nil else { fail("设备特征读取失败，请重新连接"); return }
        for characteristic in service.characteristics ?? [] {
            if requiredEndpoints.contains(where: { CBUUID(string: $0.0) == characteristic.uuid && CBUUID(string: $0.1) == service.uuid }) {
                characteristics[characteristic.uuid] = characteristic
            }
        }
        pendingServices.remove(service.uuid)
        guard pendingServices.isEmpty else { return }
        guard requiredEndpoints.allSatisfy({ characteristic($0.0)?.properties.contains(.read) == true }),
              characteristic(LightstickProtocol.colorWrite)?.properties.contains(.writeWithoutResponse) == true,
              characteristic(LightstickProtocol.challengeWrite)?.properties.contains(.write) == true else {
            fail("必要的设备读取与写入属性尚未就绪")
            return
        }
        guard value.maximumWriteValueLength(for: .withResponse) >= 39,
              value.maximumWriteValueLength(for: .withoutResponse) >= 12 else {
            fail("当前蓝牙单包容量不足，请重新连接")
            return
        }
        read(LightstickProtocol.macRead, as: .mac)
    }

    private func handleValue(_ value: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard accepts(value), phase == .initializing, expectedRead === characteristic else { return }
        expectedRead = nil
        stageTask?.cancel(); stageTask = nil
        if step == .signature && !responseWindow.isOpen(at: now) {
            fail("设备响应等待窗口已结束，请重新连接")
            return
        }
        if error != nil || characteristic.value == nil {
            if step == .signature { scheduleSignatureRead() }
            else { fail("读取设备信息失败，请重新连接") }
            return
        }
        guard let data = characteristic.value else { return }
        switch step {
        case .mac:
            do { mac = try LightstickProtocol.displayMAC(data); macBytes = data }
            catch { fail(error.localizedDescription); return }
            read(LightstickProtocol.challengeWrite, as: .compatibility)
        case .compatibility:
            read(LightstickProtocol.firmwareRead, as: .firmware)
        case .firmware:
            firmware = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))) ?? ""
            guard policy.isConfigured else { fail("请先在 App 配置中登记宝宝剑的设备摘要", allowRecovery: false); return }
            guard policy.accepts(name: deviceName, mac: mac, firmware: firmware) else {
                fail("请选择已登记且固件为 v0.20.14 的宝宝剑", allowRecovery: false)
                return
            }
            message = "正在发送设备确认请求。"
            scheduleHandshake(after: 0.3, step: .beforeChallenge) { [weak self] in self?.sendChallenge() }
        case .signature:
            guard data.count == 64 else { scheduleSignatureRead(); return }
            step = .complete
            phase = .ready
            queue.reset(); isSending = false
            message = isRestoringSession ? "设备会话已恢复并重新校验，可在前台重新开始音乐律动。"
                : rhythmIntent.rhythmRequested ? "宝宝剑已重新就绪，将跟随新的音频灯光。"
                : "设备响应结构已确认。请选择颜色发送，并观察实物效果。"
        default: return
        }
    }

    private func handleWrite(_ value: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        guard accepts(value), step == .challengeWrite, expectedWrite === characteristic else { return }
        expectedWrite = nil
        stageTask?.cancel(); stageTask = nil
        guard error == nil else { fail("设备确认请求写入失败，请重新连接"); return }
        responseWindow.start(at: now)
        scheduleSignatureRead()
    }
}

// The central and its peripheral delegates use DispatchQueue.main; keep callback ordering synchronous.
extension LightstickManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            guard self.central === central, !preview else { return }
            pendingRestored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            restoredStatePending = true
            if central.state == .poweredOn { handleCentralState(central) }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { handleCentralState(central) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard self.central === central, phase == .scanning, !backgrounded else { return }
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
            let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            guard name.uppercased().hasPrefix("LT"), advertised.contains(CBUUID(string: LightstickProtocol.lightingService)) else { return }
            discovered[peripheral.identifier] = peripheral
            let item = SwordDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            devices.removeAll { $0.id == item.id }
            devices.append(item)
            devices.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { if self.central === central { handleConnected(peripheral) } }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if self.central === central { finishConnection(peripheral, failed: true, error: error) } }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { if self.central === central { finishConnection(peripheral, failed: false, error: error) } }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { handleServices(peripheral, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { handleCharacteristics(peripheral, service: service, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { handleValue(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { handleWrite(peripheral, characteristic: characteristic, error: error) }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { if accepts(peripheral) { drain() } }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            if accepts(peripheral), invalidatedServices.contains(where: { requiredServices.contains($0.uuid) }) {
                fail("设备服务已更新，请重新连接")
            }
        }
    }
}
