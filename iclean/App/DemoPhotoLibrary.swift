#if DEBUG
    import CleanupKit
    import CoreGraphics
    import Foundation

    /// DEBUG-only synthetic photo library used by UI tests (`-UITesting`), so flows
    /// run the same way every time without the Photos permission prompt or real
    /// photos. Never compiled into release builds.
    final class DemoPhotoLibrary: PhotoLibrary, @unchecked Sendable {
        struct Asset {
            var metadata: AssetMetadata
            var image: CGImage?
            var cloudOnly: Bool
            var size: Int64?
            /// For the large scenarios: the image is drawn when its preview is asked for, so 30,000
            /// photos do not sit in memory.
            var recipe: LargeRecipe?
        }

        /// How to draw one photo of a large scenario.
        enum LargeRecipe: Sendable {
            case scene(UInt64)
            case copy(UInt64)
            case burst(UInt64, Int)
            case blurred(UInt64)
            case stripes(UInt64)
        }

        private let lock = NSLock()
        private var assets: [String: Asset] = [:]
        private var order: [String] = []
        private let scenario: String
        private var listeners: [AsyncStream<LibraryChange>.Continuation] = []
        /// `-DemoAnalysisLatencyMs N`: every preview takes N ms, like a phone's photo library.
        private let previewLatency: Duration

        init(scenario: String) {
            self.scenario = scenario
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-DemoAnalysisLatencyMs"), i + 1 < args.count,
                let ms = Int(args[i + 1])
            {
                previewLatency = .milliseconds(ms)
            } else {
                previewLatency = .zero
            }
            if scenario == "dates" {
                buildDates()
            } else if let count = Self.largeCount(scenario) {
                buildLarge(count: count)
            } else if scenario != "empty" {
                buildStandard()
            }
        }

        // MARK: Content

        private func add(
            _ id: String, kind: ItemKind = .photo, image: CGImage?, minutes: Double,
            width: Int = 4032, height: Int = 3024, favorite: Bool = false, edited: Bool = false,
            portrait: Bool = false, duration: Double? = nil, burst: String? = nil,
            albums: [String] = [], cloudOnly: Bool = false, size: Int64? = nil,
            date explicitDate: Date? = nil, added: Date? = nil, location: Bool = false
        ) {
            let date = explicitDate ?? Date(timeIntervalSince1970: 1_700_000_000 + minutes * 60)
            let m = AssetMetadata(
                assetID: id, kind: kind, captureDate: date, modificationDate: date,
                pixelWidth: width, pixelHeight: height, duration: duration, isFavorite: favorite,
                hasAdjustments: edited, isPortrait: portrait, burstID: burst, albumNames: albums,
                addedDate: added, hasLocation: location)
            assets[id] = Asset(metadata: m, image: image, cloudOnly: cloudOnly, size: size)
            order.append(id)
        }

        /// Copies of one photo that carry different dates (date-aware keepers).
        private func buildDates() {
            // Exact copies. The original keeps the date it was taken (and its location); the other
            // was saved from a message much later, dated that moment, with a bigger file.
            let a = DemoImages.scene(seed: 41)
            let saved = Date(timeIntervalSince1970: 1_694_347_200)  // 10 Sep 2023 12:00 UTC
            add(
                "date-orig", image: a, minutes: 0, size: 3_000_000,
                date: Date(timeIntervalSince1970: 1_559_402_441),  // 1 Jun 2019 15:20:41 UTC
                added: saved.addingTimeInterval(60), location: true)
            add("date-resaved", image: a, minutes: 0, size: 3_400_000, date: saved, added: saved)
            // A larger copy whose date is the start of 1970, and a smaller one with a real date.
            let b = DemoImages.scene(seed: 42)
            add(
                "date-default", image: b, minutes: 0, size: 4_000_000,
                date: Date(timeIntervalSince1970: 0))
            add(
                "date-real", image: DemoImages.resized(b, 0.5), minutes: 0, width: 2016, height: 1512,
                size: 900_000, date: Date(timeIntervalSince1970: 1_580_000_000))
        }

        /// `large30k`, `large3k`: a library of that many items shaped like a real one (about 9% screenshots,
        /// 6% videos, a third of the photos in bursts, a few copies and blurry ones), drawn on demand.
        static func largeCount(_ scenario: String) -> Int? {
            guard scenario.hasPrefix("large"), scenario.hasSuffix("k"),
                let thousands = Int(scenario.dropFirst(5).dropLast())
            else { return nil }
            return thousands * 1_000
        }

        private func buildLarge(count: Int) {
            var rng = DemoRandom(seed: 30_000)
            var clock = 1_600_000_000.0
            var n = 0
            func put(
                _ id: String, kind: ItemKind = .photo, recipe: LargeRecipe?, at t: Double,
                size: Int64, width: Int = 4032, height: Int = 3024, duration: Double? = nil
            ) {
                let date = Date(timeIntervalSince1970: t)
                let m = AssetMetadata(
                    assetID: id, kind: kind, captureDate: date, modificationDate: date,
                    pixelWidth: width, pixelHeight: height, duration: duration)
                assets[id] = Asset(
                    metadata: m, image: nil, cloudOnly: false, size: size, recipe: recipe)
                order.append(id)
            }
            while order.count < count {
                clock += 600 + rng.unit() * 40_000
                let id = "L\(n)"
                let seed = UInt64(n) &+ 1
                switch Double(n % 100) {
                case 0..<9:
                    put(id, kind: .screenshot, recipe: .stripes(seed), at: clock, size: 400_000, width: 1206, height: 2622)
                case 9..<15:
                    let big = rng.unit() < 0.1
                    put(
                        id, kind: .video, recipe: .scene(seed), at: clock,
                        size: big ? 600_000_000 : Int64(5_000_000 + rng.unit() * 90_000_000),
                        width: 1920, height: 1080, duration: 5 + rng.unit() * 120)
                case 15..<45:
                    // A burst of four shots a few seconds apart.
                    for k in 0..<4 where order.count < count {
                        put(
                            "\(id)b\(k)", recipe: .burst(seed, k), at: clock + Double(k) * 2.5,
                            size: 2_400_000)
                    }
                case 45..<50:
                    // Two copies of one photo, the second smaller.
                    put(id, recipe: .scene(seed), at: clock, size: 3_200_000)
                    if order.count < count {
                        put("\(id)c", recipe: .copy(seed), at: clock + 3_600, size: 900_000, width: 2016, height: 1512)
                    }
                case 50..<58:
                    put(id, recipe: .blurred(seed), at: clock, size: 2_000_000)
                default:
                    put(id, recipe: .scene(seed), at: clock, size: 3_000_000)
                }
                n += 1
            }
        }

        private static func image(for recipe: LargeRecipe) -> CGImage {
            let w = 256
            let h = 192
            switch recipe {
            case .scene(let seed): return DemoImages.scene(seed: seed, width: w, height: h)
            case .copy(let seed):
                return DemoImages.resized(DemoImages.scene(seed: seed, width: w, height: h), 0.5)
            case .burst(let seed, let k):
                return DemoImages.burstFrame(DemoImages.scene(seed: seed, width: w, height: h), index: k)
            case .blurred(let seed):
                return DemoImages.blurred(DemoImages.scene(seed: seed, width: w, height: h))
            case .stripes(let seed): return DemoImages.stripes(seed: seed, width: 134, height: 291)
            }
        }

        private func buildStandard() {
            // Duplicates: three copies of one photo, two of another (one a favorite),
            // and an edited version that must not be grouped with its original.
            let d1 = DemoImages.scene(seed: 11)
            add("dup1-a", image: d1, minutes: 0, size: 3_200_000)
            add("dup1-b", image: DemoImages.resized(d1, 0.5), minutes: 600, width: 2016, height: 1512, size: 900_000)
            add("dup1-c", image: DemoImages.resized(d1, 0.5), minutes: 1200, width: 2016, height: 1512, size: 850_000)
            let d2 = DemoImages.scene(seed: 22)
            add("dup2-a", image: d2, minutes: 2000, size: 3_000_000)
            add("dup2-fav", image: d2, minutes: 2600, favorite: true, albums: ["Holiday"], size: 3_000_000)
            let e = DemoImages.scene(seed: 33)
            add("edit-orig", image: e, minutes: 3000, size: 2_800_000)
            add("edit-crop", image: DemoImages.cropped(e), minutes: 3001, edited: true, size: 1_900_000)
            // Blurry photos, and a portrait shot that is blurry on purpose.
            add("blur1", image: DemoImages.blurred(DemoImages.scene(seed: 44)), minutes: 4000, size: 2_000_000)
            add("blur2", image: DemoImages.blurred(DemoImages.scene(seed: 55)), minutes: 5000, size: 2_100_000)
            add("portrait", image: DemoImages.blurred(DemoImages.scene(seed: 66)), minutes: 6000, portrait: true, size: 2_500_000)
            add("sharp", image: DemoImages.scene(seed: 77), minutes: 7000, size: 3_100_000)
            // A burst of similar shots.
            for i in 0..<5 {
                add(
                    "burst\(i)", image: DemoImages.burstFrame(DemoImages.scene(seed: 88), index: i),
                    minutes: 8000 + Double(i) / 60, burst: "B1", size: 2_400_000)
            }
            // Screenshots.
            for i in 0..<3 {
                add(
                    "shot\(i)", kind: .screenshot, image: DemoImages.stripes(seed: UInt64(100 + i)),
                    minutes: 9000 + Double(i) * 100, width: 1206, height: 2622, size: 400_000)
            }
            // Two copies of one clip and a large video. Free: no video is analyzed, so all three
            // are listed by size. Pro (-ProVideoAnalysis): the two copies are grouped.
            let v = DemoImages.scene(seed: 99)
            add("vid-hd", kind: .video, image: v, minutes: 10000, width: 1920, height: 1080, duration: 12, size: 24_000_000)
            add("vid-sd", kind: .video, image: DemoImages.resized(v, 0.5), minutes: 10100, width: 1280, height: 720, duration: 12.2, size: 9_000_000)
            add("vid-big", kind: .video, image: DemoImages.scene(seed: 111), minutes: 11000, width: 3840, height: 2160, duration: 300, size: 900_000_000)
            // Only in iCloud: not scanned.
            add("cloud", image: nil, minutes: 12000, cloudOnly: true)
        }

        // MARK: PhotoLibrary

        func authorizationStatus() -> LibraryAccess {
            switch scenario {
            case "denied": .denied
            case "limited": .limited
            default: .full
            }
        }

        func requestAuthorization() async -> LibraryAccess { authorizationStatus() }

        func fetchAllItems() async -> [AssetMetadata] {
            if scenario == "deleteDuringReview" {
                // Simulates a deletion in the Photos app while the user reviews results.
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    self.deleteElsewhere("dup1-b")
                }
            }
            return lock.withLock { order.compactMap { assets[$0]?.metadata } }
        }

        func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata] {
            lock.withLock { assetIDs.compactMap { assets[$0]?.metadata } }
        }

        func preview(for assetID: String, maxPixels: Int) async -> PreviewResult {
            if scenario == "poison", assetID == "blur1" {
                // Never returns: exercises the per-item time limit (003 FR-007).
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                return .unavailable
            }
            if scenario == "slow" { try? await Task.sleep(for: .milliseconds(1500)) }
            // Long enough to leave the app and watch the scan continue (002 quickstart).
            if scenario == "verySlow" { try? await Task.sleep(for: .seconds(6)) }
            if previewLatency > .zero { try? await Task.sleep(for: previewLatency) }
            guard let asset = lock.withLock({ assets[assetID] }) else { return .unavailable }
            let drawn = asset.recipe.map(Self.image(for:))
            guard let image = asset.image ?? drawn else { return .unavailable }
            return asset.cloudOnly ? .cloudPreview(image) : .local(image)
        }

        func localByteSize(for assetID: String) async -> Int64? {
            lock.withLock { assets[assetID]?.size }
        }

        func remove(_ assetIDs: [String]) async -> RemovalResult {
            if scenario == "cancelRemoval" {
                return RemovalResult(removed: [], failed: [], cancelled: true)
            }
            let failing: Set<String> = scenario == "removalFails" ? [assetIDs.sorted().first ?? ""] : []
            let result: RemovalResult = lock.withLock {
                var removed: [String] = []
                var failed: [String] = []
                for id in assetIDs {
                    if failing.contains(id) || assets[id] == nil {
                        failed.append(id)
                    } else {
                        assets.removeValue(forKey: id)
                        order.removeAll { $0 == id }
                        removed.append(id)
                    }
                }
                return RemovalResult(removed: removed, failed: failed)
            }
            return result
        }

        func changes() -> AsyncStream<LibraryChange> {
            let (stream, continuation) = AsyncStream<LibraryChange>.makeStream()
            lock.withLock { listeners.append(continuation) }
            return stream
        }

        /// Simulates a deletion made in the Photos app (edge-case UI test).
        func deleteElsewhere(_ id: String) {
            let listeners = lock.withLock {
                assets.removeValue(forKey: id)
                order.removeAll { $0 == id }
                return self.listeners
            }
            listeners.forEach { $0.yield(LibraryChange(removed: [id])) }
        }
    }

    /// Synthetic images for the demo library.
    enum DemoImages {
        static func scene(seed: UInt64, width: Int = 640, height: Int = 480) -> CGImage {
            var rng = DemoRandom(seed: seed)
            let ctx = context(width: width, height: height)
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for _ in 0..<60 {
                ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
                let rect = CGRect(
                    x: rng.unit() * Double(width), y: rng.unit() * Double(height),
                    width: 10 + rng.unit() * Double(width) / 3,
                    height: 10 + rng.unit() * Double(height) / 3)
                if rng.unit() > 0.5 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
            }
            return ctx.makeImage()!
        }

        static func stripes(seed: UInt64, width: Int = 402, height: Int = 874) -> CGImage {
            var rng = DemoRandom(seed: seed)
            let ctx = context(width: width, height: height)
            let band = 8 + Int(rng.unit() * 24)
            for y in stride(from: 0, to: height, by: band) {
                ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
                ctx.fill(CGRect(x: 0, y: y, width: width, height: band))
            }
            return ctx.makeImage()!
        }

        static func resized(_ image: CGImage, _ scale: Double) -> CGImage {
            let w = max(1, Int(Double(image.width) * scale))
            let h = max(1, Int(Double(image.height) * scale))
            let ctx = context(width: w, height: h)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()!
        }

        static func blurred(_ image: CGImage) -> CGImage {
            let small = resized(image, 1.0 / 12)
            let ctx = context(width: image.width, height: image.height)
            ctx.interpolationQuality = .high
            ctx.draw(small, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return ctx.makeImage()!
        }

        static func cropped(_ image: CGImage) -> CGImage {
            let w = image.width * 6 / 10
            let h = image.height * 6 / 10
            return image.cropping(to: CGRect(x: (image.width - w) / 2, y: (image.height - h) / 2, width: w, height: h))!
        }

        /// One frame of a burst: the camera moved and the subject changed a little.
        static func burstFrame(_ image: CGImage, index: Int) -> CGImage {
            let moved = shifted(image, by: index * 40)
            let ctx = context(width: image.width, height: image.height)
            ctx.draw(moved, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var rng = DemoRandom(seed: UInt64(500 + index))
            ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 200 + index * 30, y: 150, width: 140, height: 180))
            return ctx.makeImage()!
        }

        /// The same scene, shifted (like consecutive burst shots).
        static func shifted(_ image: CGImage, by pixels: Int) -> CGImage {
            let ctx = context(width: image.width, height: image.height)
            ctx.draw(image, in: CGRect(x: pixels, y: pixels / 2, width: image.width, height: image.height))
            return ctx.makeImage()!
        }

        private static func context(width: Int, height: Int) -> CGContext {
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
    }

    struct DemoRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }
#endif
