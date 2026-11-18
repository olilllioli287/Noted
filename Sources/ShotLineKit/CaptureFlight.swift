import AppKit
import QuartzCore

/// Reads where on screen a screenshot was taken. macOS stores the captured
/// area on the file, in global points with the origin at the top left of
/// the main display. Returned in AppKit screen coordinates.
func captureRect(of url: URL) -> CGRect? {
    let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
    let data: Data? = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return nil }
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? buffer : nil
    }
    guard let data,
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
          values.count == 4, let main = NSScreen.screens.first else { return nil }
    let x = CGFloat(truncating: values[0]), y = CGFloat(truncating: values[1])
    let w = CGFloat(truncating: values[2]), h = CGFloat(truncating: values[3])
    guard w > 2, h > 2 else { return nil }
    return CGRect(x: x, y: main.frame.maxY - y - h, width: w, height: h)
}

/// The capture lifting off the screen and flying up to the line. It turns
/// into the hanging card on the way: it shrinks, tilts into place and grows
/// its glass frame and clip, so there is nothing left to change on landing.
@MainActor
final class CaptureFlight {
    nonisolated static let duration: CFTimeInterval = 0.65
    /// How high the gentle arc rises halfway, in points.
    private static let arc: CGFloat = 30

    private let window: NSWindow
    private let container = CALayer()
    private let glass = CALayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let photo = CALayer()
    private let clip = CAGradientLayer()
    /// 剛拍下的瞬間一圈白框，閃一下就淡掉
    private let flash = CAShapeLayer()

    /// 飛行視窗蓋住的螢幕左下角。算位置一律用它，不用視窗現在的位置（測試時視窗會被移到畫面外）。
    private let origin0: CGPoint
    private let from: CGRect
    private var to: CGRect
    private var tilt: CGFloat
    /// The photo's proportions, for where it sits inside the card.
    private var imageSize: CGSize
    private var falling = false
    /// Played backwards: from the card on the line out to a plain image.
    private var reversed = false
    /// Which photo is flying, so its image can change on the way.
    private var tag: UUID?
    private var duration: CFTimeInterval = CaptureFlight.duration
    private var start: CFTimeInterval = 0
    private var timer: Timer?

    // 立刻回饋的飛行（begin／attach）：拍下的瞬間先在原地「彈」一下，卡片還沒掛好就先起飛，
    // 落點每一幀重讀，最後一段對準真實位置交接。
    /// 彈起的時間（秒）：放大約 3%，白框亮一下再淡掉。跟飛行重疊，不是先彈完才飛。
    private static let popDuration: CFTimeInterval = 0.14
    /// 立刻回饋的飛行本體花多久（起飛快、落地緩）
    nonisolated static let quickDuration: CFTimeInterval = 0.38
    /// 起飛前最少停多久（讓彈起先露出來）、最多等落點多久（等不到就放棄，卡片直接現身）
    private static let minHold: CFTimeInterval = 0.04
    private static let maxHold: CFTimeInterval = 0.45
    private var quick = false
    private var attached = false
    private var targetProvider: (() -> CGRect?)?
    private var targetKnown = false
    private var flightStart: CFTimeInterval?
    private var popScale: CGFloat = 1
    private var flashOpacity: Float = 0
    private var completion: () -> Void = {}

    private static var current: [CaptureFlight] = []

    /// Captures flying to the line right now. Each one holds a large image,
    /// so in a burst of captures only a couple fly and the rest drop in.
    static var flightsInProgress: Int { current.filter { !$0.falling }.count }

    /// - Parameters:
    ///   - from: the captured area, in screen coordinates.
    ///   - to: the card's frame on the line, in screen coordinates, unrotated.
    ///   - tilt: the card's resting tilt in degrees, clockwise, as SwiftUI uses.
    ///   - reversed: flies the other way, from the card out to `from`.
    static func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
                    reversed: Bool = false, duration: CFTimeInterval = CaptureFlight.duration,
                    level: NSWindow.Level? = nil, dark: Bool = false, tag: UUID? = nil, completion: @escaping () -> Void) {
        let flight = CaptureFlight(image: image, from: from, to: to, tilt: tilt, screen: screen, dark: dark)
        if let level { flight.window.level = level }
        flight.reversed = reversed
        flight.tag = tag
        flight.duration = duration
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// 拍下的瞬間（檔案一出現）就呼叫：馬上在拍攝位置顯示一個彈起的畫面，圖還沒解好先用白底，之後 `setImage`。
    /// 接著 `attach` 告訴它要飛去哪；落點出來之前它在原地彈著，不會停頓。
    static func begin(from: CGRect, on screen: NSScreen, level: NSWindow.Level? = nil, dark: Bool = false) -> CaptureFlight {
        let flight = CaptureFlight(image: nil, from: from, to: from, tilt: 0, screen: screen, dark: dark)
        if let level { flight.window.level = level }
        flight.quick = true
        flight.duration = quickDuration
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
        return flight
    }

    /// 告訴它這張卡片是誰、歪多少、落點怎麼讀（每一幀問一次，讀不到就用上一次的）。`completion` 在飛到時呼叫。
    func attach(tag: UUID, tilt: CGFloat, target: @escaping () -> CGRect?, completion: @escaping () -> Void) {
        self.tag = tag
        self.tilt = tilt
        targetProvider = target
        attached = true
        let previous = self.completion
        self.completion = { completion(); previous() }
    }

    /// 圖解好了：換上去（飛行中途換也看不出來，因為一樣的畫面）。
    func setImage(_ image: CGImage) {
        photo.backgroundColor = nil
        photo.contents = image
        imageSize = CGSize(width: image.width, height: image.height)
    }

    /// 不飛了（卡片掛不上之類）：淡掉，不呼叫 completion。
    func cancel() {
        timer?.invalidate()
        timer = nil
        fadeOut()
        CaptureFlight.current.removeAll { $0 === self }
    }

    /// The photo changed on the way, like an edit saved as it flies back.
    static func replaceImage(_ image: CGImage, tag: UUID) {
        for flight in current where flight.tag == tag {
            flight.photo.contents = image
            flight.imageSize = CGSize(width: image.width, height: image.height)
        }
    }

    /// A discarded card falling off the line, drawn over the whole screen so
    /// it is never cut by the line's strip. Same motion as the app always had:
    /// 520 points down, tilting further, fading, 0.55 s ease in.
    static func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen) {
        let flight = CaptureFlight(image: image, from: card, to: card, tilt: tilt, screen: screen)
        flight.falling = true
        flight.duration = 0.55
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
    }

    private init(image: CGImage?, from: CGRect, to: CGRect, tilt: CGFloat, screen: NSScreen, dark: Bool = false) {
        self.from = from
        self.to = to
        origin0 = screen.frame.origin
        self.tilt = tilt
        imageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? from.size
        // 測試版加 NOTED_TEST_OFFSCREEN 時，飛行視窗放到畫面外（位置照常算，只是不出現在使用者螢幕上）
        let testShift: CGFloat = DevBuild.environment["NOTED_TEST_OFFSCREEN"] != nil ? -20000 : 0
        window = NSPanel(contentRect: screen.frame.offsetBy(dx: 0, dy: testShift), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor

        container.anchorPoint = CGPoint(x: 0.5, y: 1)   // the card's top center
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.24
        container.shadowRadius = 10
        container.shadowOffset = CGSize(width: 0, height: -5)

        // 暗色面板上的卡片玻璃是暗的，飛行的卡片也要一樣，落地交接才不會閃一下亮色
        glass.backgroundColor = (dark ? NSColor(white: 0.10, alpha: 0.82) : NSColor(white: 0.97, alpha: 0.72)).cgColor
        edge.colors = dark ? [NSColor(white: 1, alpha: 0.30).cgColor, NSColor(white: 1, alpha: 0.08).cgColor]
                           : [NSColor(white: 1, alpha: 0.9).cgColor, NSColor(white: 1, alpha: 0.25).cgColor]
        edge.startPoint = CGPoint(x: 0.5, y: 1); edge.endPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = 1.5
        edge.mask = edgeMask

        photo.contents = image
        if image == nil { photo.backgroundColor = NSColor(white: 0.92, alpha: 1).cgColor }   // 圖還在解，先用白底
        photo.contentsGravity = .resize
        photo.masksToBounds = true
        photo.contentsScale = scale

        clip.colors = [NSColor(white: 0.70, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor,
                       NSColor(white: 0.82, alpha: 1).cgColor, NSColor(white: 0.62, alpha: 1).cgColor]
        clip.locations = [0, 0.35, 0.65, 1]
        clip.startPoint = CGPoint(x: 0, y: 0.5); clip.endPoint = CGPoint(x: 1, y: 0.5)
        clip.cornerRadius = 3.5
        clip.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        clip.borderWidth = 0.6

        for layer in [container, glass, edge, photo, clip] as [CALayer] { layer.contentsScale = scale }
        container.addSublayer(glass)
        container.addSublayer(photo)
        container.addSublayer(edge)
        container.addSublayer(clip)
        flash.fillColor = nil
        flash.strokeColor = NSColor.white.cgColor
        flash.lineWidth = 3
        flash.opacity = 0
        flash.contentsScale = scale
        container.addSublayer(flash)
        host.layer?.addSublayer(container)
    }

    /// 測試用：設了之後，下一個起飛的飛行會在 10%、30%、50%、70%、90% 處各存一張圖（檔名 前綴-序號.png）。
    static var debugAutoSnapshotPrefix: String?

    private func run() {
        if falling { update(1); updateFall(0) } else { update(reversed ? 1 : 0) }
        window.orderFrontRegardless()
        start = CACurrentMediaTime()
        // 立刻回饋以外的飛行（舊流程）一開始就起飛；立刻回饋的要等 attach 與落點
        if !quick { flightStart = start }
        if quick { ShotLineModule.mark("pop") }
        if !falling, let prefix = Self.debugAutoSnapshotPrefix {
            Self.debugAutoSnapshotPrefix = nil
            let extra = quick ? Self.minHold : 0
            for (i, f) in [0.1, 0.3, 0.5, 0.7, 0.9].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + extra + duration * f) { _ = Self.debugSnapshot(to: "\(prefix)-\(i + 1).png") }
            }
        }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if falling {
            let k = min(1, (now - start) / duration)
            updateFall(k)
            guard k >= 1 else { return }
            timer?.invalidate(); timer = nil
            completion()
            window.orderOut(nil)
            return
        }
        if quick {
            // 彈起：放大約 3% 再回來，白框亮一下淡掉（跟飛行重疊）
            let p = min(1, (now - start) / Self.popDuration)
            popScale = 1 + 0.03 * CGFloat(sin(Double.pi * p))
            flashOpacity = Float((1 - p) * 0.9)
            // 落點每一幀重讀：新截圖提示長出來、右欄的新一排滑進來時，終點跟著修正
            if let target = targetProvider?() {
                to = target
                targetKnown = true
            }
            if flightStart == nil {
                if attached, targetKnown, now - start >= Self.minHold {
                    flightStart = now
                    ShotLineModule.mark("fly")
                } else if now - start > Self.maxHold {
                    // 等不到落點：不飛了，卡片直接現身
                    timer?.invalidate(); timer = nil
                    completion()
                    fadeOut()
                    return
                }
            }
        }
        guard let began = flightStart else { update(0); return }
        let k = min(1, (now - began) / duration)
        update(reversed ? 1 - k : k)
        guard k >= 1 else { return }
        timer?.invalidate()
        timer = nil
        completion()
        fadeOut()
    }

    /// The real card fades in underneath; this one fades out over it.
    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func updateFall(_ raw: Double) {
        let e = CGFloat(raw * raw * raw)
        let origin = origin0
        let angle = tilt + (tilt * 7 + 20) * e
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x, y: to.maxY - origin.y - 520 * e)
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        container.opacity = Float(1 - e)
        CATransaction.commit()
    }

    /// 起飛快、落地緩
    private static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    private static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private func update(_ raw: Double) {
        let k = CGFloat(quick ? Self.easeOutCubic(raw) : Self.easeInOutCubic(raw))
        let chrome = Float(Self.smooth(Double(k), 0.35, 1))
        let origin = origin0
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }

        let w = lerp(from.width, to.width), h = lerp(from.height, to.height)
        let topX = lerp(from.midX, to.midX) - origin.x
        let topY = lerp(from.maxY, to.maxY) - origin.y + sin(.pi * k) * Self.arc
        let inset = 4 * k
        let radius = lerp(0, 16)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        container.position = CGPoint(x: topX, y: topY)
        // SwiftUI tilts clockwise for positive angles; Core Animation the other way.
        container.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * .pi / 180 * k).scaledBy(x: popScale, y: popScale))
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        flash.opacity = flashOpacity
        flash.frame = container.bounds
        flash.path = CGPath(roundedRect: container.bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        glass.frame = container.bounds
        glass.cornerRadius = radius
        glass.opacity = chrome
        edge.frame = container.bounds
        edgeMask.path = CGPath(roundedRect: container.bounds.insetBy(dx: 0.75, dy: 0.75),
                               cornerWidth: max(0, radius - 0.75), cornerHeight: max(0, radius - 0.75), transform: nil)
        edge.opacity = chrome
        // The whole photo, centred in the card and rounded itself, as the
        // card on the line shows it.
        let box = container.bounds.insetBy(dx: inset, dy: inset)
        let scale = imageSize.width > 0 && imageSize.height > 0
            ? min(box.width / imageSize.width, box.height / imageSize.height) : 1
        let pw = imageSize.width > 0 ? imageSize.width * scale : box.width
        let ph = imageSize.height > 0 ? imageSize.height * scale : box.height
        photo.frame = CGRect(x: box.midX - pw / 2, y: box.midY - ph / 2, width: pw, height: ph)
        photo.cornerRadius = min(max(0, radius - inset), pw / 2, ph / 2)
        // The clip grips the top edge: 26 points tall, 12 of them over the card.
        clip.frame = CGRect(x: w / 2 - 4.5, y: h - 12, width: 9, height: 26)
        clip.opacity = chrome
        CATransaction.commit()
    }

    // MARK: 測試用（只有測試版的除錯指令會呼叫）

    /// 把正在飛的第一個畫面存成 PNG（只畫飛行那一塊，墊深灰色背景），不需要螢幕錄影權限。
    static func debugSnapshot(to path: String) -> Bool {
        guard let flight = current.first(where: { !$0.falling }), let layer = flight.window.contentView?.layer else { return false }
        let size = flight.window.frame.size
        let area = flight.container.frame.insetBy(dx: -40, dy: -50).intersection(CGRect(origin: .zero, size: size))
        guard !area.isEmpty, let ctx = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(gray: 0.28, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: area.size))
        ctx.translateBy(x: -area.minX, y: -area.minY)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 還在畫面上的飛行視窗數（動畫跑完要是 0，不能殘留透明視窗）。
    static var debugVisibleWindows: Int { NSApp.windows.filter { $0 is NSPanel && $0.level.rawValue == NSWindow.Level.mainMenu.rawValue + 4 && $0.isVisible }.count }
    static var debugFlying: Int { current.count }
}

