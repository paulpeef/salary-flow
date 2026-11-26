import ScreenCaptureKit
import Vision

enum MeetingZoomBanner {
    struct Observation {
        var names: Set<String> = []
        var status: String
        var capturedAt: Date?
    }

    // The AX tile frames and SCWindow.frame both use global top-left points.
    // The fast path uses all four edges. The recovery path also requires an
    // independently read caption and two horizontal edges joined by a side.
    static func highlighted(in image: CGImage, window: CGRect, tiles: [MeetingAX.Tile], captionConfirmed: Bool = false) -> Set<String> {
        guard !tiles.isEmpty, window.width > 0, window.height > 0 else { return [] }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        struct Pixel {
            let r, g, b: Int
            var isHighlight: Bool { g >= 150 && g >= r - 15 && g - b >= 55 }
            func resembles(_ other: Pixel) -> Bool {
                max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) <= 34
            }
        }
        func pixel(_ x: CGFloat, _ y: CGFloat) -> Pixel? {
            let px = Int(floor((x - window.minX) * CGFloat(w) / window.width))
            let py = Int(floor((y - window.minY) * CGFloat(h) / window.height))
            guard px >= 0, px < w, py >= 0, py < h else { return nil }
            let offset = (py * w + px) * 4
            return Pixel(r: Int(data[offset]), g: Int(data[offset + 1]), b: Int(data[offset + 2]))
        }
        func framed(_ rect: CGRect) -> Bool {
            guard rect.width >= 40, rect.height >= 28, window.intersects(rect) else { return false }
            // Zoom can inset the video surface differently on each edge. Explore
            // each side locally, inside the tile's own neighbourhood.
            let margin = min(24, Int(min(rect.width, rect.height) * 0.18))
            var frameColor: Pixel?
            var masks = Array(repeating: 0, count: 4)
            for side in 0..<4 {
                for inset in -margin...margin {
                    let d = CGFloat(inset)
                    var mask = 0
                    var color = frameColor
                    for n in 1...11 {
                        let f = CGFloat(n) / 12
                        var x = rect.minX + f * rect.width, y = rect.minY + f * rect.height
                        var dx: CGFloat = 0, dy: CGFloat = 0
                        switch side {
                        case 0: x = rect.minX + d; dx = 8
                        case 1: x = rect.maxX - d; dx = -8
                        case 2: y = rect.minY + d; dy = 8
                        default: y = rect.maxY - d; dy = -8
                        }
                        guard let edge = pixel(x, y), edge.isHighlight,
                              let inner = pixel(x + dx, y + dy), !edge.resembles(inner),
                              color?.resembles(edge) != false else { continue }
                        color = edge
                        mask |= 1 << (n - 1)
                    }
                    if mask.nonzeroBitCount > masks[side].nonzeroBitCount {
                        masks[side] = mask
                        if mask.nonzeroBitCount >= 5 { frameColor = color }
                    }
                    if masks[side].nonzeroBitCount >= 9 { break }
                }
                if !captionConfirmed && masks[side].nonzeroBitCount < 8 { return false }
            }
            if masks.allSatisfy({ $0.nonzeroBitCount >= 8 }) { return true }
            guard captionConfirmed else { return false }
            let horizontal = masks[2] & masks[3]
            // Both horizontal strokes must start at the same surviving side.
            return (masks[0].nonzeroBitCount >= 8 && horizontal & 0b11111 == 0b11111) ||
                   (masks[1].nonzeroBitCount >= 8 && horizontal & 0b11111000000 == 0b11111000000)
        }
        return Set(tiles.filter { framed($0.frame) }.map(\.name))
    }

    // During a layout change AX can still put the speaker in the thumbnail
    // row. Locate thin green outlines in the same captured frame as the badge.
    static func outlineRects(in image: CGImage, window: CGRect) -> [CGRect] {
        let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let rgb = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var green = [Bool](repeating: false, count: w * h)
        for i in green.indices {
            let g = Int(rgb[4 * i + 1])
            green[i] = g >= 150 && g - Int(rgb[4 * i]) >= 45 && g - Int(rgb[4 * i + 2]) >= 55
        }
        let sx = window.width / CGFloat(w), sy = window.height / CGFloat(h)
        var result = [CGRect](), pending = [Int]()
        for i in green.indices where green[i] {
            green[i] = false
            pending.append(i)
            var minX = i % w, maxX = minX, minY = i / w, maxY = minY, count = 0
            while let at = pending.popLast() {
                let x = at % w, y = at / w
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
                for row in max(0, y - 1)...min(h - 1, y + 1) {
                    for col in max(0, x - 1)...min(w - 1, x + 1) {
                        let next = row * w + col
                        if green[next] { green[next] = false; pending.append(next) }
                    }
                }
            }
            let width = maxX - minX + 1, height = maxY - minY + 1
            guard count >= width + height, count * 3 < width * height,
                  CGFloat(width) * sx >= 60, CGFloat(height) * sy >= 40 else { continue }
            result.append(CGRect(x: window.minX + CGFloat(minX) * sx, y: window.minY + CGFloat(minY) * sy,
                                 width: CGFloat(width) * sx, height: CGFloat(height) * sy))
        }
        return result
    }

    // Re-locate the tile using the visible name badge when the carousel moves
    // or part of its border is clipped. Only read the band occupied by AX tiles.
    static func captionBorders(in image: CGImage, window: CGRect, tiles: [MeetingAX.Tile]) -> Set<String> {
        guard !tiles.isEmpty, window.width > 0, window.height > 0 else { return [] }
        let band = tiles.reduce(CGRect.null) { $0.union($1.frame.insetBy(dx: -$1.frame.width / 2, dy: -$1.frame.height / 2)) }.intersection(window)
        guard !band.isNull, !band.isEmpty else { return [] }
        let sx = CGFloat(image.width) / window.width, sy = CGFloat(image.height) / window.height
        let crop = CGRect(x: (band.minX - window.minX) * sx, y: (band.minY - window.minY) * sy,
                          width: band.width * sx, height: band.height * sy).integral
        guard let strip = image.cropping(to: crop) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "ru-RU"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: strip).perform([request])
        func key(_ text: String) -> String {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        }
        let roster = Dictionary(grouping: tiles, by: { key($0.name) })
        var relocated = [MeetingAX.Tile]()
        for item in request.results ?? [] {
            guard let text = item.topCandidates(1).first?.string, let candidates = roster[key(text)],
                  Set(candidates.map(\.name)).count == 1 else { continue }
            let box = item.boundingBox
            let x = window.minX + (crop.minX + box.minX * CGFloat(strip.width)) / sx
            let bottom = window.minY + (crop.minY + (1 - box.minY) * CGFloat(strip.height)) / sy
            // Zoom places the text just above the lower-left edge. Keep the AX
            // size and independently verify the stroke around the projected tile.
            for tile in candidates {
                let frame = CGRect(x: x - 6, y: bottom + 6 - tile.frame.height,
                                   width: tile.frame.width, height: tile.frame.height)
                relocated.append(MeetingAX.Tile(name: tile.name, frame: frame, windowFrame: window, pid: tile.pid))
            }
        }
        return highlighted(in: image, window: window, tiles: relocated, captionConfirmed: true)
    }

    // Speaker view during screen sharing has a single landscape video panel.
    // The name badge stays in its lower left even when Zoom draws no border.
    static func featuredTiles(_ tiles: [MeetingAX.Tile], window: CGRect, speakerView: Bool = false) -> [MeetingAX.Tile] {
        let visible = tiles.filter { window.intersects($0.frame) }
        if speakerView, visible.count == 1, let tile = visible.first,
           tile.frame.intersection(window).width >= window.width * 0.5,
           tile.frame.intersection(window).height >= window.height * 0.5 { return visible }
        let ordered = visible.sorted { $0.frame.width > $1.frame.width }
        guard let first = ordered.first, let last = ordered.last,
              first.frame.width >= 1.5 * last.frame.width, first.frame.height >= 1.5 * last.frame.height else { return [] }
        let featured = ordered.prefix { $0.frame.width >= first.frame.width / 1.5 && $0.frame.height >= first.frame.height / 1.5 }
        let thumbnails = ordered.dropFirst(featured.count)
        if speakerView, featured.count == 1, !thumbnails.isEmpty,
           thumbnails.allSatisfy({ !first.frame.insetBy(dx: 3, dy: 3).intersects($0.frame) }) {
            return [first]
        }
        // Zoom can hide its View options button along with the toolbar. Its
        // speaker layout still has a distinct upper stage above smaller tiles.
        guard let bottom = featured.map({ $0.frame.maxY }).max(), thumbnails.count >= 2,
              thumbnails.allSatisfy({ $0.frame.minY >= bottom - 3 }) else { return [] }
        return Array(featured)
    }

    static func panelCaption(in image: CGImage, tiles: [MeetingAX.Tile]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "ru-RU"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).filter { $0.boundingBox.width > 0.015 }
        // A second caption, a pin label or toolbar text invalidates a lone
        // participant observation. Tiny fragments at the edge are ignored.
        guard lines.count == 1, let line = lines.first, let text = line.topCandidates(1).first,
              text.confidence >= 0.7 else { return nil }
        let box = line.boundingBox
        guard box.minX <= 0.18, box.minY <= 0.18, box.midY < 0.24, box.height < 0.22 else { return nil }
        let name = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = Set(tiles.map(\.name))
        if !known.isEmpty {
            guard known.count == 1, let original = known.first,
                  original.caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return original
        }
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " .-'’_"))
        guard name.count <= 100, name.contains(where: \.isLetter),
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return name
    }

    static func badgeNames(at frame: CGRect, in image: CGImage, window: CGRect, roster: Set<String>) -> Set<String> {
        // Crop the lower-left badge in window-local pixels, including Retina.
        let sx = CGFloat(image.width) / window.width, sy = CGFloat(image.height) / window.height
        let height = min(48, frame.height / 3)
        let crop = CGRect(x: (frame.minX - window.minX) * sx, y: (frame.maxY - height - window.minY) * sy,
                          width: min(frame.width, 360) * sx, height: height * sy).integral
        guard let badge = image.cropping(to: crop) else { return [] }
        func recognize(_ input: CGImage) -> Set<String> {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["en-US", "ru-RU"]
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: input).perform([req])
            let labels = (req.results ?? []).compactMap { line -> String? in
                guard line.boundingBox.minX * CGFloat(badge.width) / sx <= 48,
                      let text = line.topCandidates(1).first, text.confidence >= 0.7 else { return nil }
                return text.string
            }
            return roster.filter { name in labels.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        }
        let names = recognize(badge)
        // Small Zoom badges can fall below Vision's text-detection threshold
        // when the window capture is scaled down. Retry only the same crop.
        guard names.isEmpty, min(sx, sy) < 2 else { return names }
        let width = badge.width * 2, heightPixels = badge.height * 2
        guard let ctx = CGContext(data: nil, width: width, height: heightPixels, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(badge, in: CGRect(x: 0, y: 0, width: width, height: heightPixels))
        guard let enlarged = ctx.makeImage() else { return [] }
        return recognize(enlarged)
    }

    static func featuredObservation(in image: CGImage, window: CGRect, tiles: [MeetingAX.Tile], layout: MeetingAX.Layout) -> Observation? {
        guard layout.canUseFeaturedTile else { return nil }
        let featured = featuredTiles(tiles, window: window, speakerView: layout.viewMode == .speaker)
        guard !featured.isEmpty else { return nil }
        guard featured.count == 1, let tile = featured.first else { return Observation(status: "multiple-featured") }
        guard !layout.muted.contains(tile.name) else { return Observation(status: "featured-muted") }
        guard badgeNames(at: tile.frame, in: image, window: window, roster: [tile.name]) == [tile.name] else {
            return Observation(status: "featured-unconfirmed")
        }
        return Observation(names: [tile.name], status: "featured-tile")
    }

    static func borderObservation(in image: CGImage, window: CGRect, tiles: [MeetingAX.Tile]) -> Observation? {
        guard !tiles.isEmpty else { return nil }
        let roster = Set(tiles.map(\.name))
        let direct = highlighted(in: image, window: window, tiles: tiles)
        if !direct.isEmpty {
            var names = Set<String>()
            for tile in tiles where direct.contains(tile.name) {
                let badge = badgeNames(at: tile.frame, in: image, window: window, roster: roster)
                names.formUnion(badge.isEmpty ? [tile.name] : badge)
            }
            return Observation(names: names, status: names.count == 1 ? "tile-border" : "ambiguous-borders")
        }
        let outlines = outlineRects(in: image, window: window).enumerated().map { i, rect in
            MeetingAX.Tile(name: String(i), frame: rect, windowFrame: window, pid: tiles[0].pid)
        }
        // A menu can obscure one edge. Every inferred contour still needs its own roster-matched badge.
        let verified = highlighted(in: image, window: window, tiles: outlines, captionConfirmed: true)
        var names = Set<String>()
        for outline in outlines where verified.contains(outline.name) {
            names.formUnion(badgeNames(at: outline.frame, in: image, window: window, roster: roster))
        }
        if names.isEmpty { names = captionBorders(in: image, window: window, tiles: tiles) }
        return names.isEmpty ? nil : Observation(names: names, status: "tile-caption-border")
    }

    static func observe(reading: MeetingAX.Reading, readTiles: Bool) async -> Observation {
        guard CGPreflightScreenCaptureAccess() else { return Observation(status: "screen-permission") }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return Observation(status: "window-unavailable")
        }
        func matches(pid: pid_t, frame: CGRect?, window: SCWindow) -> Bool {
            guard let a = frame else { return false }
            let b = window.frame
            return pid == window.owningApplication?.processID && abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3 &&
                abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
        }
        var samples: [Observation] = []
        for window in content.windows {
            guard MeetingAX.zoomIDs.contains(window.owningApplication?.bundleIdentifier ?? "") else { continue }
            let matching = readTiles ? reading.tiles.filter { matches(pid: $0.pid, frame: $0.windowFrame, window: window) } : []
            let layout = reading.layouts.first { matches(pid: $0.pid, frame: $0.frame, window: window) }
            let title = (window.title ?? "").lowercased()
            let panel = readTiles && (title == "zoom floating video window" || layout?.floating == true)
            let meeting = window.windowLayer == 0 && window.frame.width >= 240 &&
                ["meeting", "конференц", "webinar", "вебинар"].contains(where: title.contains)
            guard panel || !matching.isEmpty || meeting else { continue }
            samples.append(await observe(window: window, tiles: matching, panel: panel, layout: layout))
        }
        guard !samples.isEmpty else { return Observation(status: "window-unavailable") }
        // Prefer explicit speaker evidence over the inferred speaker-view caption.
        let direct = samples.filter { !$0.names.isEmpty && !["sharing-panel", "featured-tile"].contains($0.status) }
        let named = direct.isEmpty ? samples.filter { !$0.names.isEmpty } : direct
        if let first = named.first {
            let names = Set(named.flatMap(\.names))
            return Observation(names: names, status: names.count == 1 ? first.status : "ambiguous", capturedAt: first.capturedAt)
        }
        if let sample = samples.first(where: { ["multiple-featured", "featured-unconfirmed", "featured-muted"].contains($0.status) }) { return sample }
        if let sample = samples.first(where: { $0.status == "no-border" }) { return sample }
        if samples.contains(where: { $0.status == "no-banner" }) {
            return Observation(status: readTiles && !reading.tiles.isEmpty ? "tile-window-unmatched" : "no-banner")
        }
        return Observation(status: "capture-failed")
    }

    private static func observe(window: SCWindow, tiles matching: [MeetingAX.Tile], panel: Bool, layout: MeetingAX.Layout?) async -> Observation {
        let config = SCStreamConfiguration()
        let width = window.frame.width, height = matching.isEmpty && !panel ? min(180, window.frame.height) : window.frame.height
        config.sourceRect = CGRect(x: 0, y: 0, width: width, height: height)
        config.width = Int(min(2400, width * 1.5))
        config.height = max(1, Int(height * CGFloat(config.width) / width))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return Observation(status: "capture-failed")
        }
        let capturedAt = Date()
        if var observation = borderObservation(in: image, window: window.frame, tiles: matching) {
            observation.capturedAt = capturedAt
            return observation
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ru-RU", "en-US"]
        let fraction = min(1, 180 / height)
        req.regionOfInterest = CGRect(x: 0, y: 1 - fraction, width: 1, height: fraction)
        try? VNImageRequestHandler(cgImage: image).perform([req])
        let banners = Set((req.results ?? []).compactMap { $0.topCandidates(1).first.flatMap { MeetingAX.speakerName($0.string) } })
        if banners.isEmpty, layout?.fixedVideo != true {
            if panel, (layout == nil || layout?.complete == true), let name = panelCaption(in: image, tiles: matching) {
                return Observation(names: [name], status: "sharing-panel", capturedAt: capturedAt)
            }
            if !panel, let layout, var observation = featuredObservation(in: image, window: window.frame, tiles: matching, layout: layout) {
                observation.capturedAt = capturedAt
                return observation
            }
        }
        return Observation(names: banners, status: banners.isEmpty ? (matching.isEmpty ? "no-banner" : "no-border") : "banner", capturedAt: capturedAt)
    }
}
