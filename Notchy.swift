import AppKit
import SwiftUI
import IOKit.ps
import IOKit.pwr_mgt


struct Metric { var value = "–", sub = " ", frac = 0.0 }

@MainActor final class Model: ObservableObject {
    @Published var expanded = false
    @Published var clips: [String] = UserDefaults.standard.stringArray(forKey: "clips") ?? []
    @Published var ram = Metric()
    @Published var down = Metric()
    @Published var up = Metric()
    @Published var cpu = Metric()
    @Published var battery = Metric()
    @Published var pinned = Set(UserDefaults.standard.stringArray(forKey: "pinnedClips") ?? [])
    var closePanel: () -> Void = {}
    @Published var hovered: String?
    @Published var copied: String?

    @Published var awakeUntil: Date?
    @Published var awakeLabel = "Off"
    private var awakeAssertion: IOPMAssertionID = 0
    static let awakeOptions: [(String, TimeInterval)] = [("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200),
                                                          ("4 hours", 14400), ("8 hours", 28800), ("Until turned off", .infinity)]

    let sounds = KeySounds()
    @Published var soundsOn = UserDefaults.standard.object(forKey: "soundsOn") as? Bool ?? true
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 45

    private var lastChange = NSPasteboard.general.changeCount
    private var lastTicks: (used: UInt64, total: UInt64)?
    private var wasOnAC: Bool?
    private var lastNet: (at: Date, bytes: [String: (i: UInt32, o: UInt32)])?
    private var netPeak = 1_000_000.0

    init() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.pollClipboard() } }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.pollScreenshots() } }
        refresh()
        sounds.volume = Float(volume / 100)
        if soundsOn { sounds.use("eg-oreo") }
    }

    func setSounds(_ on: Bool) {
        soundsOn = on
        UserDefaults.standard.set(on, forKey: "soundsOn")
        sounds.use(on ? "eg-oreo" : nil)
    }

    func setVolume(_ v: Double) {
        volume = v
        sounds.volume = Float(v / 100)
        UserDefaults.standard.set(v, forKey: "volume")
    }

    func keepAwake(_ seconds: TimeInterval?) {
        if awakeAssertion != 0 { IOPMAssertionRelease(awakeAssertion); awakeAssertion = 0 }
        awakeUntil = nil
        if let seconds, IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "Notchy: keep awake" as CFString, &awakeAssertion) == kIOReturnSuccess {
            awakeUntil = seconds.isInfinite ? .distantFuture : Date().addingTimeInterval(seconds)
        }
        updateAwakeLabel()
    }

    private func updateAwakeLabel() {
        guard let until = awakeUntil else { awakeLabel = "Off"; return }
        if until == .distantFuture { awakeLabel = "On"; return }
        let left = Int(until.timeIntervalSinceNow)
        if left <= 0 { keepAwake(nil); return }
        awakeLabel = left >= 3600 ? "\(left / 3600)h \(left % 3600 / 60)m left" : "\(max(1, left / 60))m left"
    }

    static let imgTag = "\u{1}img:"
    static let imageDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Notchy/images")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func imageURL(_ clip: String) -> URL? {
        clip.hasPrefix(imgTag) ? imageDir.appendingPathComponent(String(clip.dropFirst(imgTag.count))) : nil
    }
    private var thumbs: [String: NSImage] = [:]
    func thumb(_ clip: String) -> NSImage? {
        if let t = thumbs[clip] { return t }
        guard let url = Self.imageURL(clip), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 200] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        img.accessibilityDescription = "\(props[kCGImagePropertyPixelWidth] ?? 0) × \(props[kCGImagePropertyPixelHeight] ?? 0)"
        thumbs[clip] = img
        return img
    }

    func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = pb.types ?? []
        let skip = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        if skip.contains(where: { types.contains(.init($0)) }) { return }
        let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if text.isEmpty, !types.contains(.fileURL), let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            addImage(raw)
            return
        }
        guard !text.isEmpty, let str = pb.string(forType: .string) else { return }
        add(str)
    }

    private func addImage(_ raw: Data) {
        guard let png = raw.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? raw
                : NSBitmapImageRep(data: raw)?.representation(using: .png, properties: [:]) else { return }
        if let existing = clips.first(where: { Self.imageURL($0).map { (try? Data(contentsOf: $0)) == png } ?? false }) {
            add(existing); return
        }
        let name = UUID().uuidString + ".png"
        try? png.write(to: Self.imageDir.appendingPathComponent(name))
        add(Self.imgTag + name)
    }

    private let shotDir: URL = {
        if let p = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }()
    private let launched = Date()
    private var seenShots = Set<String>()
    private var loggedShotError = false

    func pollScreenshots() {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: shotDir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles) }
        catch { if !loggedShotError { NSLog("Notchy: cannot read \(shotDir.path): \(error)"); loggedShotError = true }; return }
        for f in files where !seenShots.contains(f.path) {
            seenShots.insert(f.path)
            guard let created = try? f.resourceValues(forKeys: [.creationDateKey]).creationDate, created > launched else { continue }
            guard getxattr(f.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0,
                  let data = try? Data(contentsOf: f) else { continue }
            addImage(data)
        }
    }

    private func add(_ clip: String) {
        clips.removeAll { $0 == clip }
        clips.insert(clip, at: 0)
        let keep = Set(clips.filter { !pinned.contains($0) }.prefix(30))
        for old in clips where !pinned.contains(old) && !keep.contains(old) { remove(file: old) }
        clips = clips.filter { pinned.contains($0) || keep.contains($0) }
        UserDefaults.standard.set(clips, forKey: "clips")
    }

    var ordered: [String] { clips.filter(pinned.contains) + clips.filter { !pinned.contains($0) } }

    func togglePin(_ clip: String) {
        if pinned.contains(clip) { pinned.remove(clip) } else { pinned.insert(clip) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedClips")
    }

    private func remove(file clip: String) {
        thumbs[clip] = nil
        if let url = Self.imageURL(clip) { try? FileManager.default.removeItem(at: url) }
    }

    func copy(_ clip: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let url = Self.imageURL(clip), let png = try? Data(contentsOf: url) {
            pb.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        } else {
            pb.setString(clip, forType: .string)
        }
    }

    func paste(_ clip: String) {
        copy(clip)
        guard AXIsProcessTrusted() else { return }
        closePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
                e?.flags = .maskCommand
                e?.post(tap: .cgSessionEventTap)
            }
        }
    }

    func dragItem(_ clip: String) -> NSItemProvider {
        if let url = Self.imageURL(clip) { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        return NSItemProvider(object: clip as NSString)
    }

    func clearClips() {
        clips.filter { !pinned.contains($0) }.forEach(remove(file:))
        clips = clips.filter(pinned.contains)
        UserDefaults.standard.set(clips, forKey: "clips")
    }


    private func refreshNetwork() {
        var now: [String: (i: UInt32, o: UInt32)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return }
        defer { freeifaddrs(head) }
        for p in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let a = p?.pointee, a.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let d = a.ifa_data else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let data = d.assumingMemoryBound(to: if_data.self).pointee
            now[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        defer { lastNet = (Date(), now) }
        guard let last = lastNet else { return }
        let secs = max(Date().timeIntervalSince(last.at), 0.1)
        var i = 0.0, o = 0.0
        for (k, v) in now { if let l = last.bytes[k] { i += Double(v.i &- l.i); o += Double(v.o &- l.o) } }
        i /= secs; o /= secs
        netPeak = max(netPeak, i, o)
        let rate = { (b: Double) in ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .decimal) + "/s" }
        down = Metric(value: rate(i), frac: i / netPeak)
        up = Metric(value: rate(o), frac: o / netPeak)
    }

    func refresh() {
        updateAwakeLabel()
        let trusted = AXIsProcessTrusted()
        if trusted != axTrusted {
            axTrusted = trusted
            if trusted, soundsOn { sounds.relisten() }
        }

        var vm = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &vm, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) } }) == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let used = (Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            ram = Metric(value: String(format: "%.1f / %.0f GB", used / 1_073_741_824, total / 1_073_741_824), frac: used / total)
        }

        var load = host_cpu_load_info()
        var c = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &load, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &c) } }) == KERN_SUCCESS {
            let t = load.cpu_ticks
            let used = UInt64(t.0) + UInt64(t.1) + UInt64(t.3), total = used + UInt64(t.2)
            if let l = lastTicks, total > l.total {
                let f = Double(used - l.used) / Double(total - l.total)
                cpu = Metric(value: "\(Int(f * 100))%", sub: "\(ProcessInfo.processInfo.activeProcessorCount) cores", frac: f)
            }
            lastTicks = (used, total)
        }

        refreshNetwork()

        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        guard let src = list.first, let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else {
            battery = Metric(value: "AC", sub: "No battery", frac: 1); return
        }
        let pct = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let mins = d[kIOPSTimeToEmptyKey] as? Int ?? -1

        if wasOnAC == true && !onAC { UserDefaults.standard.set(Date(), forKey: "unplugged") }
        wasOnAC = onAC
        var sub = charging ? "Charging" : onAC ? "Plugged in" : mins > 0 ? "\(mins / 60)h \(mins % 60)m left" : "On battery"
        if !onAC, let t = UserDefaults.standard.object(forKey: "unplugged") as? Date {
            sub += " · off " + RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date()).replacingOccurrences(of: " ago", with: "")
        }
        battery = Metric(value: "\(pct)%", sub: sub, frac: Double(pct) / 100)
    }
}


let dim = Color.white.opacity(0.45)
extension View {
    func pane(_ radius: CGFloat = 16) -> some View {
        let r = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(r.fill(.white.opacity(0.07)))
            .overlay(r.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

struct NotchView: View {
    @ObservedObject var m: Model
    let notch: CGSize, full: CGSize

    var body: some View {
        let ear: CGFloat = m.expanded ? 14 : 6
        let size = m.expanded ? full : CGSize(width: notch.width + ear * 2, height: notch.height)
        let shape = NotchShape(ear: ear, bottom: m.expanded ? 28 : 9)
        let notchStop = notch.height / full.height
        ZStack(alignment: .top) {
            Color.clear.glassEffect(.regular.tint(.black.opacity(0.32)), in: shape)
            shape.fill(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: notchStop),
                .init(color: .black.opacity(0.45), location: notchStop + 0.22),
                .init(color: .black.opacity(0.12), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            shape.fill(.black).opacity(m.expanded ? 0 : 1)
            shape.stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.06), .white.opacity(0.22)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .opacity(m.expanded ? 1 : 0)
            if m.expanded {
                content.transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6)))
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(m.expanded ? 0.5 : 0), radius: 26, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: m.expanded)
    }

    var content: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { DualCard(icon: "cpu", title: "System", rows: [("CPU", m.cpu, Accent.cpu, 0.8), ("MEM", m.ram, Accent.memory, 0.85)])
                              DualCard(icon: "arrow.up.arrow.down", title: "Network", rows: [("↓", m.down, Accent.disk, 2), ("↑", m.up, Accent.cpu, 2)]) }
                    GridRow { StatCard(icon: batteryIcon, title: "Battery", m: m.battery, accent: Accent.power, warnBelow: 0.2).gridCellColumns(2) }
                }
                HStack(spacing: 8) {
                    ControlPill(icon: m.awakeUntil == nil ? "cup.and.saucer" : "cup.and.saucer.fill", title: "Keep awake",
                                value: m.awakeLabel, accent: Accent.warn, active: m.awakeUntil != nil) {
                        ForEach(Model.awakeOptions, id: \.0) { opt in Button(opt.0) { m.keepAwake(opt.1) } }
                        if m.awakeUntil != nil { Divider(); Button("Turn off") { m.keepAwake(nil) } }
                    }
                    let needsAccess = m.soundsOn && !m.axTrusted
                    ControlPill(icon: needsAccess ? "exclamationmark.triangle.fill" : m.soundsOn ? "keyboard.fill" : "keyboard", title: "Key sounds",
                                value: needsAccess ? "Needs permission" : m.soundsOn ? "Oreo · \(Int(m.volume))%" : "Off",
                                accent: needsAccess ? Accent.warn : Accent.memory, active: m.soundsOn) {
                        if needsAccess {
                            Button("Grant Accessibility access…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            Divider()
                        }
                        Button(m.soundsOn ? "Turn off" : "Turn on") { m.setSounds(!m.soundsOn) }
                        Divider()
                        ForEach([25.0, 45, 60, 80, 100], id: \.self) { v in
                            Button { m.setVolume(v) } label: { Text("Volume \(Int(v))%" + (Int(m.volume) == Int(v) ? "  ✓" : "")) }
                        }
                    }
                }
                }
                .frame(width: 300)

                ClipList(m: m)
            }
        }
        .padding(.top, notch.height + 10)
        .padding(.horizontal, 30)
        .padding(.bottom, 16)
    }

    var batteryIcon: String {
        let f = m.battery.frac
        if m.battery.sub.hasPrefix("Charging") || m.battery.sub.hasPrefix("Plugged") { return "bolt.fill" }
        return f > 0.87 ? "battery.100percent" : f > 0.62 ? "battery.75percent" : f > 0.37 ? "battery.50percent" : f > 0.12 ? "battery.25percent" : "battery.0percent"
    }
}

struct NotchShape: Shape {
    var ear: CGFloat, bottom: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let b = min(bottom, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + b, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - b), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

enum Accent {
    static let memory = [Color(hex: 0xA78BFA), Color(hex: 0xF472B6)]
    static let cpu    = [Color(hex: 0x67E8F9), Color(hex: 0x3B82F6)]
    static let disk   = [Color(hex: 0x6EE7B7), Color(hex: 0x14B8A6)]
    static let power  = [Color(hex: 0xBEF264), Color(hex: 0x34D399)]
    static let warn   = [Color(hex: 0xFCD34D), Color(hex: 0xF97316)]
    static let danger = [Color(hex: 0xFB923C), Color(hex: 0xEF4444)]
}

struct StatCard: View {
    let icon: String, title: String, m: Metric, accent: [Color]
    var warnAbove = 2.0, warnBelow = -1.0

    var body: some View {
        let tint = tinted(m.frac, accent, warnAbove: warnAbove, warnBelow: warnBelow)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(title.uppercased()).foregroundStyle(dim)
            }
            .font(.system(size: 9, weight: .semibold)).tracking(0.7)

            Text(m.value)
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())

            Meter(frac: m.frac, colors: tint)

            Text(m.sub).font(.system(size: 10, weight: .medium)).foregroundStyle(dim).lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pane()
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: m.value)
    }
}

func tinted(_ frac: Double, _ accent: [Color], warnAbove: Double = 2, warnBelow: Double = -1) -> [Color] {
    frac < warnBelow / 2 || frac > (warnAbove + 1) / 2 ? Accent.danger : frac < warnBelow || frac > warnAbove ? Accent.warn : accent
}

struct DualCard: View {
    let icon: String, title: String
    let rows: [(label: String, m: Metric, accent: [Color], warnAbove: Double)]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: rows[0].accent, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(title.uppercased()).foregroundStyle(dim)
            }
            .font(.system(size: 9, weight: .semibold)).tracking(0.7)
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(dim)
                        Spacer(minLength: 4)
                        Text(r.m.value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).contentTransition(.numericText())
                    }
                    Meter(frac: r.m.frac, colors: tinted(r.m.frac, r.accent, warnAbove: r.warnAbove))
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pane()
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: rows.map(\.m.value))
    }
}

struct Meter: View {
    let frac: Double, colors: [Color]

    var body: some View {
        GeometryReader { g in
            let w = max(5, g.size.width * min(max(frac, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.35))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center)))
                    .frame(width: w)
                    .shadow(color: colors.last!.opacity(0.7), radius: 5)
                    .shadow(color: colors.first!.opacity(0.35), radius: 2)
            }
        }
        .frame(height: 5)
    }
}

struct ControlPill<Items: View>: View {
    let icon: String, title: String, value: String, accent: [Color], active: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(LinearGradient(colors: accent, startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(dim))
                    .shadow(color: active ? accent.last!.opacity(0.6) : .clear, radius: 4)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(0.6).foregroundStyle(dim)
                    Text(value).font(.system(size: 11, weight: .medium)).lineLimit(1).contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(dim)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .pane(12)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

struct ClipList: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("CLIPBOARD", systemImage: "doc.on.clipboard")
                Spacer()
                if m.clips.contains(where: { !m.pinned.contains($0) }) { Button("Clear") { withAnimation { m.clearClips() } }.buttonStyle(.plain) }
            }
            .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(dim)
            .padding(.horizontal, 4)

            if m.clips.isEmpty {
                Text("Things you copy show up here")
                    .font(.system(size: 11)).foregroundStyle(dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(m.ordered, id: \.self) { c in
                            ClipRow(text: c, image: m.thumb(c), hover: m.hovered == c, copied: m.copied == c, pinned: m.pinned.contains(c)) {
                                m.paste(c)
                                withAnimation { m.copied = c }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { if m.copied == c { m.copied = nil } } }
                            } onPin: {
                                withAnimation { m.togglePin(c) }
                            } onHover: { h in
                                withAnimation(.easeOut(duration: 0.12)) { if h { m.hovered = c } else if m.hovered == c { m.hovered = nil } }
                            }
                            .onDrag { m.dragItem(c) }
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pane()
    }
}

struct ClipRow: View {
    let text: String, image: NSImage?, hover: Bool, copied: Bool, pinned: Bool
    let action: () -> Void, onPin: () -> Void, onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
          Button(action: action) {
            HStack(spacing: 6) {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Image")
                        Text("\(image.accessibilityDescription ?? "") · drag to share")
                            .font(.system(size: 10)).foregroundStyle(dim)
                    }
                } else {
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "arrow.turn.down.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(copied ? .green : dim)
                    .opacity(hover || copied ? 1 : 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)

          Button(action: onPin) {
              Image(systemName: pinned ? "pin.fill" : "pin")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(pinned ? AnyShapeStyle(Accent.warn[0]) : AnyShapeStyle(dim))
                  .frame(width: 18, height: 18)
                  .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .opacity(hover || pinned ? 1 : 0)
          .help(pinned ? "Unpin" : "Pin to keep this clip")
        }
        .font(.system(size: 12))
        .padding(.vertical, 5).padding(.leading, 8).padding(.trailing, 4)
        .background(Color.white.opacity(hover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover(perform: onHover)
        .help(image == nil ? text : "Click to paste · drag into any app")
    }
}


@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var panel: NSPanel!
    var notchRect = NSRect.zero, openRect = NSRect.zero
    var hoverTask: Task<Void, Never>?
    var status: NSStatusItem!
    var mouseWasInside = false

    func makeStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notchy")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Panel", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }

    @objc func showPanel() { mouseWasInside = false; setOpen(true) }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        model.closePanel = { [weak self] in self?.setOpen(false) }
        layout()
        panel.orderFrontRegardless()
        makeStatusItem()
        watchAwake()

        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.expanded == true { self?.setOpen(false) } }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.track() }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func layout() {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let barH = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : s.frame.maxY - s.visibleFrame.maxY
        var notchW: CGFloat = 190
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea { notchW = s.frame.width - l.width - r.width }
        let notch = CGSize(width: notchW, height: max(barH, 24))
        let full = CGSize(width: 640, height: notch.height + 248)
        let rect = { (sz: CGSize) in NSRect(x: s.frame.midX - sz.width / 2, y: s.frame.maxY - sz.height, width: sz.width, height: sz.height) }
        notchRect = rect(notch)
        openRect = rect(full)
        panel.setFrame(openRect.insetBy(dx: -110, dy: 0).offsetBy(dx: 0, dy: -110).union(openRect), display: true)
        panel.contentView = NSHostingView(rootView: NotchView(m: model, notch: notch, full: full))
        setOpen(false)
    }

    var menuOpen = false

    func track() {
        if menuOpen { return }
        let p = NSEvent.mouseLocation
        if model.expanded {
            let inside = openRect.insetBy(dx: -6, dy: -6).contains(p)
            if inside { mouseWasInside = true } else if mouseWasInside, NSEvent.pressedMouseButtons == 0 { setOpen(false) }
        } else if notchRect.insetBy(dx: -4, dy: -4).contains(p) {
            guard hoverTask == nil else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                hoverTask = nil
                if !Task.isCancelled, notchRect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) { mouseWasInside = true; setOpen(true) }
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
        }
    }

    var awakeWatch: Any?
    func watchAwake() {
        awakeWatch = model.$awakeUntil.sink { [weak self] until in
            self?.status.button?.image = NSImage(systemSymbolName: until == nil ? "rectangle.topthird.inset.filled" : "cup.and.saucer.fill",
                                                 accessibilityDescription: "Notchy")
        }
    }

    func setOpen(_ open: Bool) {
        panel.ignoresMouseEvents = !open
        if !open { model.hovered = nil }
        if model.expanded != open { model.expanded = open }
    }
}

@main enum Main {
    @MainActor static let delegate = AppDelegate()
    static let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                                reason: "Key sounds and notch panel")
    @MainActor static func main() {
        let app = NSApplication.shared
        _ = activity
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
