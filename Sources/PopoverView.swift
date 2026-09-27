import SwiftUI

private let defaultAccent = Color(red: 0.98, green: 0.36, blue: 0.55)
private let defaultAccent2 = Color(red: 0.55, green: 0.36, blue: 0.98)

struct PopoverView: View {
    @ObservedObject var store: MediaStore
    @ObservedObject var artwork = ArtworkCache.shared

    private var hero: MediaItem? { store.selected }
    private var accent: Color { hero.flatMap { artwork.accent(for: $0.artworkKey) }.map(Color.init(nsColor:)) ?? defaultAccent }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                if store.showSettings {
                    SettingsView()
                } else {
                if store.needsAccessibility { permissionBanner }
                if let hero {
                    HeroCard(item: hero, accent: accent, store: store)
                        .id(hero.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    let others = store.items.filter { $0.id != hero.id }
                    if !others.isEmpty { sessionList(others) }
                } else {
                    EmptyState()
                }
                }
                footer
            }
        }
        .frame(width: 380)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.selectedID)
        .animation(.easeInOut(duration: 0.25), value: store.items.map(\.id))
    }

    // Blurred artwork wash behind everything, tinted with the artwork's accent.
    private var backdrop: some View {
        ZStack {
            if let image = artwork.image(for: hero?.artworkKey) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 380).blur(radius: 50).saturation(1.5).opacity(0.5)
                    .clipped()
            }
            LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.6), value: hero?.artworkKey)
    }

    private var header: some View {
        HStack(spacing: 8) {
            EqualizerBars(active: store.nowPlaying != nil, color: accent).frame(width: 16, height: 14)
            Text("正在播放").font(.system(size: 15, weight: .bold, design: .rounded))
            if store.items.count > 1 {
                Text("\(store.items.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(accent.opacity(0.22)))
                    .foregroundStyle(accent)
            }
            Spacer()
            if !store.showSettings { IconButton(symbol: "arrow.clockwise", size: 12, help: "刷新") { store.refresh() } }
            IconButton(symbol: store.showSettings ? "xmark" : "gearshape", size: 12, help: store.showSettings ? "关闭设置" : "设置") {
                withAnimation(.easeInOut(duration: 0.2)) { store.showSettings.toggle() }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("读取汽水音乐需要辅助功能权限").font(.system(size: 12, weight: .semibold))
                Text("系统设置 › 隐私与安全性 › 辅助功能").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("去授权") { store.requestAccessibility() }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func sessionList(_ others: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("其他会话").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 4)
            let rows = VStack(spacing: 2) {
                ForEach(others) { item in
                    SessionRow(item: item, store: store) { store.selectedID = item.id }
                }
            }
            .padding(.horizontal, 8)
            // Only scroll when the list would make the popover too tall.
            if others.count > 4 {
                ScrollView { rows }.frame(height: 58 * 4.5)
            } else {
                rows
            }
        }
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            Text("Media Monitor").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("退出", systemImage: "power").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Rectangle().fill(.primary.opacity(0.03)))
    }
}

// MARK: - Hero

struct HeroCard: View {
    let item: MediaItem
    let accent: Color
    @ObservedObject var store: MediaStore

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(item: item, size: 92, corner: 16, accent: accent)
                    .shadow(color: accent.opacity(item.isPlaying ? 0.55 : 0.25), radius: item.isPlaying ? 18 : 10, y: 6)
                    .scaleEffect(item.isPlaying ? 1 : 0.94)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: item.isPlaying)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        SourceChip(item: item)
                        if item.isLive { LiveBadge(active: item.isPlaying) }
                    }
                    Text(item.title).font(.system(size: 16, weight: .bold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.artist.isEmpty {
                        Text(item.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if item.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Scrubber(position: item.livePosition(at: context.date), duration: item.duration,
                             enabled: item.canSeek, accent: accent) { store.perform(.seek($0), on: item) }
                }
            }

            // Transport centred on the card; the focus button sits at the trailing edge, clear of it.
            ZStack {
                HStack(spacing: item.canSkip ? 14 : 18) {
                    if item.canSkip { IconButton(symbol: "gobackward.10", size: 15, help: "后退 10 秒") { store.perform(.skip(-10), on: item) } }
                    let hasTrackButtons = item.canPrevious || item.canNext
                    if hasTrackButtons { IconButton(symbol: "backward.fill", size: 17, help: "上一个", enabled: item.canPrevious) { store.perform(.previous, on: item) } }
                    PlayPauseButton(playing: item.isPlaying, accent: accent) { store.perform(.toggle, on: item) }
                    if hasTrackButtons { IconButton(symbol: "forward.fill", size: 17, help: "下一个", enabled: item.canNext) { store.perform(.next, on: item) } }
                    if item.canSkip { IconButton(symbol: "goforward.10", size: 15, help: "快进 10 秒") { store.perform(.skip(10), on: item) } }
                }
                if item.canFocus {
                    HStack {
                        Spacer()
                        IconButton(symbol: item.kind == .browser ? "macwindow.on.rectangle" : "arrow.up.forward.app", size: 13,
                                   help: item.kind == .browser ? "切换到该标签页" : "打开 \(item.appName)") { store.perform(.focus, on: item) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

struct LiveBadge: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(active ? Color.red : Color.secondary).frame(width: 5, height: 5)
            Text("直播")
        }
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill((active ? Color.red : Color.secondary).opacity(0.14)))
        .foregroundStyle(active ? Color.red : Color.secondary)
    }
}

struct SourceChip: View {
    let item: MediaItem
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: appIcon(bundleID: item.iconBundleID)).resizable().frame(width: 13, height: 13)
            Text(item.kind == .browser ? hostOrApp : item.appName).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(.primary.opacity(0.08)))
        .foregroundStyle(.secondary)
    }
    private var hostOrApp: String { item.appName }
}

// MARK: - Rows

struct SessionRow: View {
    let item: MediaItem
    @ObservedObject var store: MediaStore
    let select: () -> Void
    @ObservedObject private var artwork = ArtworkCache.shared
    @LocalState private var hover = false

    var body: some View {
        let accent = artwork.accent(for: item.artworkKey).map(Color.init(nsColor:)) ?? defaultAccent
        HStack(spacing: 10) {
            ArtworkView(item: item, size: 40, corner: 9, accent: accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Image(nsImage: appIcon(bundleID: item.iconBundleID)).resizable().frame(width: 11, height: 11)
                    Text(item.subtitle == item.appName ? item.appName : "\(item.subtitle) · \(item.appName)")
                        .lineLimit(1)
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if item.duration > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        MiniProgress(fraction: item.livePosition(at: context.date) / item.duration, accent: accent)
                    }
                }
            }
            Spacer(minLength: 4)
            if item.isPlaying { EqualizerBars(active: true, color: accent).frame(width: 14, height: 12) }
            Button { store.perform(.toggle, on: item) } label: {
                Image(systemName: item.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(hover ? accent.opacity(0.25) : Color.primary.opacity(0.07)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain).help(item.isPlaying ? "暂停" : "播放")
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help("点击显示为主卡片")
    }
}

struct MiniProgress: View {
    let fraction: Double
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(accent).frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 2.5)
        .padding(.top, 1)
    }
}

// MARK: - Controls

struct Scrubber: View {
    let position: Double
    let duration: Double
    let enabled: Bool
    let accent: Color
    let onSeek: (Double) -> Void
    @LocalState private var dragValue: Double?
    @LocalState private var hover = false

    var body: some View {
        let shown = dragValue ?? position
        let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
        let active = enabled && (hover || dragValue != nil)
        VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [accent.opacity(0.75), accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(active ? 8 : 5, geo.size.width * fraction))
                        .shadow(color: accent.opacity(0.6), radius: active ? 6 : 3)
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: 12, height: 12)
                        .offset(x: geo.size.width * fraction - 6)
                        .opacity(active ? 1 : 0)
                        .scaleEffect(dragValue != nil ? 1.2 : 1)
                }
                .frame(height: active ? 7 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(enabled ? DragGesture(minimumDistance: 0)
                    .onChanged { g in dragValue = min(max(g.location.x / geo.size.width, 0), 1) * duration }
                    .onEnded { _ in if let v = dragValue { onSeek(v) }; dragValue = nil } : nil)
            }
            .frame(height: 14)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
            HStack {
                Text(formatTime(shown))
                Spacer()
                Text("-" + formatTime(max(0, duration - shown)))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

struct PlayPauseButton: View {
    let playing: Bool
    let accent: Color
    let action: () -> Void
    @LocalState private var hover = false
    @LocalState private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if playing {
                    Circle().stroke(accent.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 1.35 : 1).opacity(pulse ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                }
                Circle()
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.7), defaultAccent2.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: accent.opacity(0.55), radius: hover ? 12 : 7, y: 3)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: playing ? 0 : 1.5)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 50, height: 50)
            .scaleEffect(hover ? 1.07 : 1)
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hover = h } }
        .onAppear { pulse = true }
        .help(playing ? "暂停" : "播放")
        .keyboardShortcut(.space, modifiers: [])
    }
}

struct IconButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    var enabled = true
    let action: () -> Void
    @LocalState private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 16, height: size + 16)
                .background(Circle().fill(Color.primary.opacity(hover && enabled ? 0.1 : 0)))
                .foregroundStyle(enabled ? Color.primary.opacity(0.85) : Color.primary.opacity(0.25))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(help)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Decoration

struct ArtworkView: View {
    let item: MediaItem
    let size: CGFloat
    let corner: CGFloat
    let accent: Color
    @ObservedObject private var cache = ArtworkCache.shared

    var body: some View {
        ZStack {
            if let image = cache.image(for: item.artworkKey) {
                Image(nsImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [accent, defaultAccent2], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(nsImage: appIcon(bundleID: item.iconBundleID)).resizable()
                    .frame(width: size * 0.5, height: size * 0.5)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.3), value: item.artworkKey)
    }
}

/// Animated level bars; they settle flat when nothing plays.
struct EqualizerBars: View {
    let active: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { i in
                    let phase = t * (3.2 + Double(i) * 0.9) + Double(i) * 1.7
                    let level = active ? 0.3 + 0.7 * abs(sin(phase) * cos(phase * 0.37)) : 0.22
                    GeometryReader { geo in
                        Capsule().fill(color)
                            .frame(height: geo.size.height * level)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
    }
}

struct EmptyState: View {
    @LocalState private var float = false
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [defaultAccent.opacity(0.35), defaultAccent2.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 74, height: 74).blur(radius: 12)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(LinearGradient(colors: [defaultAccent, defaultAccent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .offset(y: float ? -3 : 3)
                    .animation(.easeInOut(duration: 2).repeatForever(), value: float)
            }
            Text("此刻很安静").font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("播放音乐或视频后会出现在这里\n汽水音乐 · 抖音 · 哔哩哔哩 · 虎牙直播 · LX Music · IINA · Chrome 网页")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .onAppear { float = true }
    }
}

/// Equivalent of @State. In the macOS 27 SDK @State is a macro whose plugin ships only with Xcode,
/// so a Command Line Tools build wraps the State storage type directly.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private let storage: State<Value>
    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}

// MARK: - Settings

struct SettingsView: View {
    @LocalState private var installed = false
    @LocalState private var chromeMissing = false
    @LocalState private var opened = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: appIcon(bundleID: ChromeExtension.chromeBundleID)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chrome 扩展").font(.system(size: 13, weight: .semibold))
                        Text("让 Chrome 里所有网页的音视频出现在这里").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if installed {
                        Button {} label: { Label("已安装", systemImage: "checkmark") }
                            .controlSize(.small).disabled(true).help("Chrome 扩展已安装")
                    } else {
                        Button(opened ? "重新打开" : "安装") { install() }.controlSize(.small)
                    }
                }
                if !installed {
                    if chromeMissing {
                        Label("请先安装该浏览器（Google Chrome）", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chrome 不允许其他程序直接安装扩展。点「安装」后会打开 Chrome 的扩展页，并在访达中选中扩展文件夹，然后：")
                            Text("1. 打开扩展页右上角的「开发者模式」")
                            Text("2. 把访达中选中的「ChromeExtension」文件夹拖进扩展页")
                        }
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        // Re-checked for as long as the page is open, so installing in Chrome flips it without reopening.
        // (A Timer.publish stored in the view would restart on every popover refresh and never fire.)
        .task {
            while !Task.isCancelled {
                installed = await Task.detached(priority: .utility) { ChromeExtension.isInstalled }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func install() {
        switch ChromeExtension.install() {
        case .chromeMissing: chromeMissing = true
        case .opened: chromeMissing = false; opened = true
        }
    }
}
