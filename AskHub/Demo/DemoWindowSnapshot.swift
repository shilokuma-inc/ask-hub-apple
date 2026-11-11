#if DEBUG && os(macOS)
import AppKit

/// Mac の窓を、アプリ自身が PNG に書き出す（DEBUG だけ）。
///
/// SSH で入った Mac（macOS 27 の Mac mini など）では画面収録の許可が無く `screencapture` が使えないので、アプリが自分の窓を書き出す。
/// 起動引数: `-demoWindowSize 900x600`（窓の中身の大きさ）・`-demoAppearance light|dark`・
/// `-demoPress "説明を求める|送る"`（名前で探して順に押す。末尾の `*` は前方一致）・`-demoSettings YES`（設定の窓を開く）・
/// `-demoSnapshot <名前>`（コンテナの tmp に、窓ごとに `<名前>-<番号>.png` を書く。シートは別の窓になる）
enum DemoWindowSnapshot {
    static func start(defaults: UserDefaults = .standard) {
        let snapshot = defaults.string(forKey: "demoSnapshot")
        let size = defaults.string(forKey: "demoWindowSize").flatMap(Self.size(from:))
        let appearance = defaults.string(forKey: "demoAppearance")
        let presses = defaults.string(forKey: "demoPress")?.split(separator: "|").map(String.init) ?? []
        let opensSettings = defaults.bool(forKey: "demoSettings")
        guard snapshot != nil || size != nil || appearance != nil || !presses.isEmpty || opensSettings else {
            return
        }
        Task { @MainActor in
            // App の init の時点では NSApp がまだ無いので、起動してから外観を変える
            switch appearance {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
            try? await Task.sleep(for: .seconds(2))
            if let size, let window = mainWindow() {
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                frame.origin = NSPoint(x: 80, y: max(40, (window.screen?.visibleFrame.maxY ?? 1_000) - frame.height - 20))
                window.setFrame(frame, display: true)
            }
            // macOS 27 では、支援技術がつながるまで SwiftUI がアクセシビリティの木を作らないので、つながったことにする
            if !presses.isEmpty {
                for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                    NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: attribute)
                }
            }
            if opensSettings {
                openSettings()
            }
            for label in presses {
                try? await Task.sleep(for: .seconds(1.5))
                press(label)
            }
            guard let snapshot else {
                return
            }
            try? await Task.sleep(for: .seconds(2.5))
            write(name: snapshot)
        }
    }

    private static func size(from value: String) -> NSSize? {
        let parts = value.split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && $0.sheetParent == nil }
    }

    /// アプリのメニューの「設定…」（⌘,）を実行する
    private static func openSettings() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else {
            log("設定… のメニューが見つかりません")
            return
        }
        menu.performActionForItem(at: index)
    }

    /// 窓（シートを含む）のアクセシビリティの要素から、ラベルの一致するものを探して押す
    private static func press(_ label: String) {
        for window in NSApp.windows.filter(\.isVisible).reversed() {
            guard let element = find(label, in: window, depth: 0) else {
                continue
            }
            if element.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                element.perform(NSSelectorFromString("accessibilityPerformPress"))
            } else {
                element.perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXPress")
            }
            return
        }
        log("\(label) が見つかりません")
        if let window = NSApp.windows.first(where: \.isVisible) {
            dump(window, depth: 0)
        }
    }

    /// 新しい書き方（`accessibilityTitle` など）と古い書き方（`accessibilityAttributeValue:`）の両方で読む
    private static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let property = "accessibility" + name
        if object.responds(to: NSSelectorFromString(property)) {
            return object.value(forKey: property)
        }
        if object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) {
            return object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AX" + name)?.takeUnretainedValue()
        }
        return nil
    }

    private static func find(_ label: String, in element: Any, depth: Int) -> NSObject? {
        guard depth < 60, let object = element as? NSObject else {
            return nil
        }
        // Mac のボタンは名前を label ではなく title に持つ
        let names = ["Label", "Title", "Description"].compactMap { attribute(object, $0) as? String }
        let role = attribute(object, "Role").map { "\($0)" }
        // 末尾が * なら前方一致（行のボタンは中の文字をつないだ名前になる）
        let matches = names.contains { $0 == label || (label.hasSuffix("*") && $0.hasPrefix(label.dropLast())) }
        if matches, role != NSAccessibility.Role.staticText.rawValue {
            return object
        }
        for child in (attribute(object, "Children") as? [Any]) ?? [] {
            if let found = find(label, in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func dump(_ element: Any, depth: Int) {
        guard depth < 40, let object = element as? NSObject else {
            return
        }
        let values = ["Role", "Label", "Title", "Description"].map { "\(attribute(object, $0) ?? "-")" }
        log(String(repeating: " ", count: depth) + "\(type(of: object)) " + values.joined(separator: " | "))
        for child in (attribute(object, "Children") as? [Any]) ?? [] {
            dump(child, depth: depth + 1)
        }
    }

    private static func log(_ message: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("demo-snapshot.log")
        let line = Data("\(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// 自分の窓は画面収録の許可なしで撮れる。`CGWindowListCreateImage` は macOS 15 の SDK で使えなくなったので、実行時に引く
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func write(name: String) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            log("CGWindowListCreateImage が見つかりません")
            return
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
        for (index, window) in windows.enumerated() {
            // kCGWindowListOptionIncludingWindow = 1 << 3、kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
            guard let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            let url = directory.appendingPathComponent("\(name)-\(index).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log(url.path)
        }
    }
}
#endif
