import AppKit
import AVFoundation

@MainActor final class KeySounds {
    static let dir = Bundle.main.resourceURL!.appendingPathComponent("Packs")
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var sounds: [Int: AVAudioPCMBuffer] = [:]
    private var monitor: Any?
    private var configWatch: Any?
    private var lastKey = Date()
    private var idleTimer: Timer?
    private var trustTimer: Timer?

    var volume: Float = 0.5 { didSet { engine.mainMixerNode.outputVolume = volume } }

    func use(_ id: String?) {
        sounds = [:]
        players.forEach { $0.stop() }
        guard let id, let c = Self.config(id), let defines = c["defines"] as? [String: Any] else { stopListening(); return }
        let folder = Self.dir.appendingPathComponent(id)

        if c["key_define_type"] as? String == "multi" {
            var cache: [String: AVAudioPCMBuffer] = [:]
            for (k, v) in defines {
                guard let code = Int(k), let file = v as? String else { continue }
                if cache[file] == nil { cache[file] = Self.read(folder.appendingPathComponent(file)) }
                sounds[code] = cache[file]
            }
        } else if let file = c["sound"] as? String, let all = Self.read(folder.appendingPathComponent(file)) {
            let rate = all.format.sampleRate
            for (k, v) in defines {
                guard let code = Int(k), let r = v as? [Double], r.count == 2 else { continue }
                sounds[code] = Self.slice(all, from: Int(r[0] / 1000 * rate), count: Int(r[1] / 1000 * rate))
            }
        }
        guard let format = sounds.values.first?.format else { return }

        engine.stop()
        players.forEach { engine.detach($0) }
        players = (0..<12).map { _ in AVAudioPlayerNode() }
        for p in players { engine.attach(p); engine.connect(p, to: engine.mainMixerNode, format: format) }
        engine.mainMixerNode.outputVolume = volume
        do { try engine.start() } catch { NSLog("Notchy sounds: \(error)") }
        startListening()
    }

    private func play(_ macKey: UInt16) {
        guard let code = Self.keymap[macKey], let buf = sounds[code], buf.format == players.first?.outputFormat(forBus: 0) else { return }
        lastKey = Date()
        if !engine.isRunning { try? engine.start() }
        let p = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        p.scheduleBuffer(buf, at: nil, options: .interrupts)
        p.play()
    }

    func relisten() {
        guard !sounds.isEmpty else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        startListening()
    }

    private func startListening() {
        guard monitor == nil else { return }
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    t.invalidate()
                    self?.startListening()
                }
            }
            return
        }
        idleTimer?.invalidate()
        if let configWatch { NotificationCenter.default.removeObserver(configWatch) }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine.isRunning, Date().timeIntervalSince(self.lastKey) > 20 else { return }
                self.engine.pause()
            }
        }
        configWatch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.engine.start() }
        }
    }

    private func stopListening() {
        trustTimer?.invalidate()
        idleTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let configWatch { NotificationCenter.default.removeObserver(configWatch) }
        monitor = nil
        configWatch = nil
        engine.stop()
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            if !e.isARepeat { play(e.keyCode) }
        case .flagsChanged:
            if e.keyCode == 57 { play(57); return }
            if let flag = Self.modifierFlag[e.keyCode], e.modifierFlags.contains(flag) { play(e.keyCode) }
        default: break
        }
    }

    private static func config(_ id: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(id)/config.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func read(_ url: URL) -> AVAudioPCMBuffer? {
        guard let f = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil else { return nil }
        return b
    }

    private static func slice(_ b: AVAudioPCMBuffer, from start: Int, count: Int) -> AVAudioPCMBuffer? {
        let n = min(count, Int(b.frameLength) - start)
        guard start >= 0, n > 0, let src = b.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(n)), let dst = out.floatChannelData else { return nil }
        for ch in 0..<Int(b.format.channelCount) { memcpy(dst[ch], src[ch] + start, n * MemoryLayout<Float>.size) }
        out.frameLength = AVAudioFrameCount(n)
        return out
    }

    static let modifierFlag: [UInt16: NSEvent.ModifierFlags] = [
        56: .shift, 60: .shift, 59: .control, 62: .control, 58: .option, 61: .option, 55: .command, 54: .command, 63: .function,
    ]

    static let keymap: [UInt16: Int] = [
        53: 1, 18: 2, 19: 3, 20: 4, 21: 5, 23: 6, 22: 7, 26: 8, 28: 9, 25: 10, 29: 11, 27: 12, 24: 13, 51: 14,
        48: 15, 12: 16, 13: 17, 14: 18, 15: 19, 17: 20, 16: 21, 32: 22, 34: 23, 31: 24, 35: 25, 33: 26, 30: 27, 36: 28,
        59: 29, 0: 30, 1: 31, 2: 32, 3: 33, 5: 34, 4: 35, 38: 36, 40: 37, 37: 38, 41: 39, 39: 40, 50: 41,
        56: 42, 42: 43, 6: 44, 7: 45, 8: 46, 9: 47, 11: 48, 45: 49, 46: 50, 43: 51, 47: 52, 44: 53, 60: 54,
        58: 56, 49: 57, 57: 58,
        122: 59, 120: 60, 99: 61, 118: 62, 96: 63, 97: 64, 98: 65, 100: 66, 101: 67, 109: 68, 103: 87, 111: 88,
        62: 3613, 61: 3640, 55: 3675, 54: 3676,
        115: 3655, 116: 3657, 119: 3663, 121: 3665, 117: 3667,
        126: 57416, 123: 57419, 124: 57421, 125: 57424,
        76: 3612, 63: 3613,
    ]
}
