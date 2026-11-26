import AppKit
import CoreText

func checkZoomTiles(_ check: (String, Bool) -> Void) {
    let parsed = MeetingAX.tileName(role: "Video render", labels: ["Example Person, Computer audio unmuted, Video on"])
    check("из плитки Zoom читается только имя", parsed == "Example Person")
    check("строка списка участников не считается плиткой",
          MeetingAX.tileName(role: "AXRow", labels: ["Example Person, Computer audio unmuted, Video on"]) == nil)

    // Deliberately different global and local coordinates, with synthetic pixels
    // in top-to-bottom order as returned by screen capture.
    let window = CGRect(x: -320, y: 90, width: 300, height: 240)
    let a = CGRect(x: 15, y: 12, width: 120, height: 76)
    let b = CGRect(x: 152, y: 140, width: 116, height: 80)
    let tiles = [("A", a), ("B", b)].map {
        MeetingAX.Tile(name: $0.0, frame: $0.1.offsetBy(dx: window.minX, dy: window.minY), windowFrame: window, pid: 1)
    }
    let large = MeetingAX.Tile(name: "C", frame: CGRect(x: -300, y: 100, width: 270, height: 140), windowFrame: window, pid: 1)
    let other = MeetingAX.Tile(name: "D", frame: large.frame.offsetBy(dx: 1, dy: 1), windowFrame: window, pid: 1)
    let thumbnails = [a,b].enumerated().map { index, rect in
        MeetingAX.Tile(name: String(index), frame: CGRect(x: window.minX + CGFloat(index) * 145, y: window.minY + 155,
                         width: rect.width, height: rect.height), windowFrame: window, pid: 1)
    }
    check("равная галерея не выделяет докладчика", MeetingZoomBanner.featuredTiles(tiles, window: window).isEmpty)
    check("единственная увеличенная плитка", MeetingZoomBanner.featuredTiles(thumbnails + [large], window: window).map(\.name) == ["C"])
    check("два увеличенных докладчика неоднозначны", MeetingZoomBanner.featuredTiles(thumbnails + [large, other], window: window).count == 2)
    var layout = MeetingAX.Layout(pid: 1, frame: window)
    layout.inspect(role: "AXButton", labels: ["Switch to speaker/gallery/multi-speaker view"])
    check("команда смены раскладки не указывает текущий режим", layout.viewMode == nil)
    layout.inspect(role: "AXButton", labels: ["View options, Multi-speaker"])
    layout.inspect(role: "AXButton", labels: ["Request captions, 6 of 14, not pinned"])
    check("закрепление кнопки не мешает определять докладчика", !layout.fixedVideo)
    layout.complete = true
    for (name, mode): (String, MeetingAX.Layout.ViewMode) in [("Speaker", .speaker), ("Gallery", .gallery),
        ("Dynamic gallery", .dynamicGallery), ("Immersive", .immersive), ("Multi-speaker", .multiSpeaker)] {
        layout.inspect(role: "AXButton", labels: ["View options, " + name])
        check("раскладка " + name, layout.viewMode == mode && layout.canUseFeaturedTile == (mode == .speaker))
    }
    var multi = layout
    multi.mainMeeting = true
    let imageWidth = 600, imageHeight = 480
    let ctx = CGContext(data: nil, width: imageWidth, height: imageHeight, bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    let stageTile = MeetingAX.Tile(name: "Example Person", frame: large.frame, windowFrame: window, pid: 1)
    let label = NSAttributedString(string: stageTile.name, attributes: [
        .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white
    ])
    ctx.textPosition = CGPoint(x: (large.frame.minX - window.minX + 8) * 2,
                               y: (window.maxY - large.frame.maxY + 8) * 2)
    CTLineDraw(CTLineCreateWithAttributedString(label), ctx)
    let screenshot = ctx.makeImage()!
    func observe(_ layout: MeetingAX.Layout, _ stage: [MeetingAX.Tile]? = nil) -> MeetingZoomBanner.Observation? {
        MeetingZoomBanner.featuredObservation(in: screenshot, window: window, tiles: thumbnails + (stage ?? [stageTile]), layout: layout)
    }
    check("Multi-speaker: одна крупная подписанная плитка без рамки", observe(multi)?.names == [stageTile.name])
    let small = CGContext(data: nil, width: 300, height: 240, bitsPerComponent: 8, bytesPerRow: 300 * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(screenshot, in: CGRect(x: 0, y: 0, width: 300, height: 240))
    check("Multi-speaker: мелкая подпись в уменьшенном кадре",
          MeetingZoomBanner.featuredObservation(in: small.makeImage()!, window: window, tiles: thumbnails + [stageTile], layout: multi)?.names == [stageTile.name])
    check("Multi-speaker: другое имя на крупной плитке", observe(multi, [large])?.status == "featured-unconfirmed")
    check("Multi-speaker: два крупных участника", observe(multi, [stageTile,other])?.status == "multiple-featured")
    check("Multi-speaker: равные плитки", observe(multi, []) == nil)
    var guarded = multi
    guarded.muted = [stageTile.name]
    check("Multi-speaker: выключенный микрофон", observe(guarded)?.status == "featured-muted")
    guarded = multi; guarded.fixedVideo = true
    check("Multi-speaker: закреплённое видео", observe(guarded) == nil)
    guarded = multi; guarded.sharing = true
    check("Multi-speaker: демонстрация экрана", observe(guarded) == nil)
    guarded = multi; guarded.complete = false
    check("Multi-speaker: неполные данные Zoom", observe(guarded) == nil)
    let sideTile = MeetingAX.Tile(name: "A", frame: CGRect(x: -65, y: 115, width: 44, height: 50), windowFrame: window, pid: 1)
    let stage = MeetingAX.Tile(name: "C", frame: CGRect(x: -320, y: 100, width: 240, height: 180), windowFrame: window, pid: 1)
    check("Speaker с одной боковой миниатюрой", MeetingZoomBanner.featuredTiles([stage,sideTile], window: window, speakerView: true).map(\.name) == ["C"])
    check("Speaker со скрытыми миниатюрами", MeetingZoomBanner.featuredTiles([stage], window: window, speakerView: true).map(\.name) == ["C"])
    check("одиночная миниатюра не считается сценой", MeetingZoomBanner.featuredTiles([sideTile], window: window, speakerView: true).isEmpty)
    check("имя из отдельного значения Accessibility", MeetingAX.statusName(role: "AXStaticText", description: "Active speaker", value: "Мария") == "Мария")
    check("имя участника без признака речи не используется", MeetingAX.statusName(role: "AXGroup", description: "Participant", value: "Мария") == nil)
    layout.inspect(role: "AXGroup", labels: ["Example Person, Pinned"])
    check("распознаны режим и закрепление", layout.viewMode == .multiSpeaker && layout.fixedVideo)
    func read(frames: [CGRect], solid: Bool = false, occluded: CGRect = .null, confirmed: Bool = false, findOutlines: Bool = false) -> Set<String> {
        let w = 600, h = 480
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        for y in 0..<h {
            for x in 0..<w {
                let p = CGPoint(x: CGFloat(x)/2, y: CGFloat(y)/2)
                if !occluded.contains(p), frames.contains(where: { $0.contains(p) && (solid || !$0.insetBy(dx: 3, dy: 3).contains(p)) }) {
                    let i = (w*y+x)*4
                    bytes[i] = 175; bytes[i+1] = 238; bytes[i+2] = 30
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4*w,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        if findOutlines {
            let found = MeetingZoomBanner.outlineRects(in: image, window: window)
            return Set(found.compactMap { outline in
                tiles.first(where: { $0.frame == outline })?.name
            })
        }
        return MeetingZoomBanner.highlighted(in: image, window: window, tiles: tiles, captionConfirmed: confirmed)
    }
    check("рамка верхней плитки на Retina", read(frames: [a]) == ["A"])
    check("рамка нижней плитки на Retina", read(frames: [b]) == ["B"])
    check("смещение плитки при демонстрации", read(frames: [a.offsetBy(dx: -8, dy: 6)]) == ["A"])
    check("обе рамки дают неоднозначное наблюдение", read(frames: [a,b]) == ["A","B"])
    check("зелёный фон не считается рамкой", read(frames: [a], solid: true).isEmpty)
    let covered = CGRect(x: a.minX + a.width * 0.61, y: 0, width: 100, height: 100)
    check("закрытая справа рамка с подтверждённой подписью", read(frames: [a], occluded: covered, confirmed: true) == ["A"])
    check("частичная рамка требует видимой подписи", read(frames: [a], occluded: covered).isEmpty)
    check("заливка с подписью не считается частичной рамкой", read(frames: [a], solid: true, occluded: covered, confirmed: true).isEmpty)
    check("геометрия двух зелёных контуров извлекается из пикселей", read(frames: [a,b], findOutlines: true) == ["A","B"])
    check("зелёная заливка не образует отдельный тонкий контур", read(frames: [a], solid: true, findOutlines: true).isEmpty)
    check("без рамки имя не назначается", read(frames: []).isEmpty)
}
