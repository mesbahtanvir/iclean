import Foundation

/// Version 4 of the baseline library: 73 small assets that cover every category, the keeper
/// rules, the false-positive controls, capture dates, favorites, albums and locations.
///
/// Version 2 dropped the duplicate videos of version 1: the app does not analyze videos (004
/// FR-004a, 016), so videos are only listed by size and two copies of one clip must not be
/// grouped. Version 3 added copies that differ in their dates, location or a
/// default date, to prove the date-aware keeper rule (the copy with the most probable capture
/// date is kept) on every device. Version 4 made the later-dated copy of dup-G the larger file,
/// so that the old size rule and the date rule disagree and only the date rule keeps the right copy.
///
/// Every file name carries the version, so a changed catalog never reuses assets that an older
/// one imported into the Photos library.
public enum BaselineCatalogV4 {
    public static let version = 4
    public static let albumTitle = "iclean Baseline"
    public static let tripAlbum = "iclean Baseline Trip"

    /// 2024-03-01 12:00:00 UTC. Groups are spread hours apart so that only the bursts are
    /// time neighbours.
    static let start = Date(timeIntervalSince1970: 1_709_294_400)

    public static func make() -> BaselineCatalog {
        var assets: [BaselineAsset] = []
        var slot = 0.0

        /// Next capture time: seven hours after the previous slot.
        func nextDate() -> Date {
            slot += 7
            return start.addingTimeInterval(slot * 3600)
        }

        func add(
            _ id: String, _ recipe: BaselineRecipe, kind: BaselineKind = .photo,
            date: Date? = nil, favorite: Bool = false, albums: [String] = [],
            expected: BaselineCategory, group: String? = nil, keeper: Bool = false,
            checkKeeper: Bool = false, location: Bool = false, note: String,
            informational: Bool = false
        ) {
            assets.append(
                BaselineAsset(
                    id: id, filename: "BASE\(version)_\(id).\(recipe.format.fileExtension)", kind: kind,
                    recipe: recipe, captureDate: date ?? nextDate(), favorite: favorite,
                    albums: albums, expected: expected, group: group, keeper: keeper,
                    checkKeeper: checkKeeper, location: location, note: note,
                    informational: informational))
        }

        func jpeg(_ base: BaselineRecipe.Base, _ steps: [BaselineRecipe.Step] = [], q: Double = 0.9)
            -> BaselineRecipe
        {
            BaselineRecipe(base: base, steps: steps, format: .jpeg(quality: q))
        }

        // MARK: Duplicate photos (the same image at another size, quality or format)

        func dupGroup(
            _ g: String, seed: UInt64, albums: [String] = [],
            variants: [(String, BaselineRecipe, Bool, Bool, Date?)], note: String
        ) {
            for (id, recipe, keeper, favorite, date) in variants {
                add(
                    "\(g)\(id)", recipe, date: date, favorite: favorite,
                    albums: albums, expected: .duplicates, group: g, keeper: keeper,
                    checkKeeper: true, note: note)
            }
        }

        // A: three copies; the full-size one is the keeper (highest resolution).
        let sA: UInt64 = 101
        let dA = nextDate()
        dupGroup(
            "dup-A", seed: sA,
            variants: [
                ("1", jpeg(.scene(seed: sA), q: 0.92), true, false, dA),
                ("2", jpeg(.scene(seed: sA), [.resize(0.6)], q: 0.8), false, false, dA + 3600),
                ("3", jpeg(.scene(seed: sA), [.resize(0.5), .recompress(0.4)], q: 0.8), false, false, dA + 7200),
            ], note: "Same image at three sizes and qualities; the largest is kept.")

        // B: a PNG and a smaller JPEG of the same image.
        let sB: UInt64 = 102
        let dB = nextDate()
        dupGroup(
            "dup-B", seed: sB,
            variants: [
                ("1", BaselineRecipe(base: .scene(seed: sB), format: .png), true, false, dB),
                ("2", jpeg(.scene(seed: sB), [.resize(0.7)], q: 0.85), false, false, dB + 3600),
            ], note: "A PNG and a smaller JPEG: a format change counts as a copy.")

        // C: four copies, as a chat app would produce.
        let sC: UInt64 = 103
        let dC = nextDate()
        dupGroup(
            "dup-C", seed: sC,
            variants: [
                ("1", jpeg(.scene(seed: sC)), true, false, dC),
                ("2", jpeg(.scene(seed: sC), [.resize(0.4)], q: 0.7), false, false, dC + 3600),
                ("3", jpeg(.scene(seed: sC), [.recompress(0.3)], q: 0.5), false, false, dC + 7200),
                ("4", jpeg(.scene(seed: sC), [.resize(0.8), .recompress(0.6)], q: 0.8), false, false, dC + 10800),
            ], note: "Four copies at different sizes and compression.")

        // D: the smaller copy is a favorite, so it is the one kept.
        let sD: UInt64 = 104
        let dD = nextDate()
        dupGroup(
            "dup-D", seed: sD,
            variants: [
                ("1", jpeg(.scene(seed: sD)), false, false, dD),
                ("2", jpeg(.scene(seed: sD), [.resize(0.5)], q: 0.8), true, true, dD + 3600),
            ], note: "A favorite is always kept, even when it is the smaller copy.")

        // E: copies taken years apart: duplicates do not depend on time.
        let sE: UInt64 = 105
        dupGroup(
            "dup-E", seed: sE,
            variants: [
                ("1", jpeg(.scene(seed: sE)), true, false, Date(timeIntervalSince1970: 1_620_648_000)),
                ("2", jpeg(.scene(seed: sE), [.resize(0.8)], q: 0.85), false, false, Date(timeIntervalSince1970: 1_715_342_400)),
            ], note: "Same image three years apart.")

        // F: three copies that all sit in a user album.
        let sF: UInt64 = 106
        let dF = nextDate()
        dupGroup(
            "dup-F", seed: sF, albums: [tripAlbum],
            variants: [
                ("1", jpeg(.scene(seed: sF)), true, false, dF),
                ("2", jpeg(.scene(seed: sF), [.resize(0.6)], q: 0.8), false, false, dF + 3600),
                ("3", jpeg(.scene(seed: sF), [.recompress(0.4)], q: 0.6), false, false, dF + 7200),
            ], note: "Copies inside a user album: removing them also removes them from it.")

        // G: exact copies, the later-dated one made by saving the photo again.
        let sG: UInt64 = 107
        add(
            "dup-G1", jpeg(.scene(seed: sG), q: 0.75),
            date: Date(timeIntervalSince1970: 1_559_402_441),  // 1 Jun 2019 15:20:41 UTC
            expected: .duplicates, group: "dup-G", keeper: true, checkKeeper: true,
            note: "Exact copies: the earlier date is the probable capture date, so it is kept.")
        add(
            "dup-G2", jpeg(.scene(seed: sG), q: 0.98),
            date: Date(timeIntervalSince1970: 1_694_347_200),  // 10 Sep 2023 12:00:00 UTC
            expected: .duplicates, group: "dup-G", checkKeeper: true,
            note: "The same image saved again years later and dated that moment, as a larger file.")

        // H: exact copies, one of which lost its location.
        let sH: UInt64 = 108
        let dH = nextDate()
        add(
            "dup-H1", jpeg(.scene(seed: sH)), date: dH, expected: .duplicates, group: "dup-H",
            checkKeeper: true, note: "A copy without its location (re-saved by an app).")
        add(
            "dup-H2", jpeg(.scene(seed: sH)), date: dH.addingTimeInterval(1800),
            expected: .duplicates, group: "dup-H", keeper: true, checkKeeper: true, location: true,
            note: "The copy that still has its location is kept, though it is dated a little later.")

        // I: a default date on the larger copy.
        let sI: UInt64 = 109
        add(
            "dup-I1", jpeg(.scene(seed: sI)), date: Date(timeIntervalSince1970: 0),
            expected: .duplicates, group: "dup-I", checkKeeper: true,
            note: "The larger copy is dated 1 Jan 1970, a default that cannot be a capture date.")
        add(
            "dup-I2", jpeg(.scene(seed: sI), [.resize(0.5)], q: 0.8), date: nextDate(),
            expected: .duplicates, group: "dup-I", keeper: true, checkKeeper: true,
            note: "The smaller copy has a real date and is kept.")

        // MARK: Controls: nothing may flag these

        add(
            "crop-A", jpeg(.scene(seed: sA), [.crop(0.6)]), expected: .none,
            note: "A crop of dup-A's image is an edit, not a duplicate.")
        add(
            "crop-B", jpeg(.scene(seed: sC), [.crop(0.8)]), expected: .none,
            note: "A crop of dup-C's image is an edit, not a duplicate.")
        for i in 1...3 {
            add(
                "sky-\(i)", jpeg(.lowTexture(seed: UInt64(120 + i))), expected: .none,
                note: "Sharp but featureless: must not be called blurry or a duplicate.")
        }
        for i in 1...16 {
            add(
                "unique-\(i)", jpeg(.scene(seed: UInt64(130 + i))), expected: .none,
                note: "A sharp, unrelated photo: the false-positive control.")
        }

        // MARK: Similar shots (several frames of one moment)

        func burst(_ g: String, seed: UInt64, frames: Int, gap: Double) {
            let t0 = nextDate()
            for i in 0..<frames {
                add(
                    "\(g)-\(i + 1)", jpeg(.burstFrame(sceneSeed: seed, index: i)),
                    date: t0.addingTimeInterval(Double(i) * gap), expected: .similar, group: g,
                    note: "Frame \(i + 1) of \(frames): the camera drifts and a subject walks.")
            }
        }
        burst("sim-A", seed: 201, frames: 4, gap: 2)
        let simADate = assets.last!.captureDate
        burst("sim-B", seed: 202, frames: 3, gap: 3)
        burst("sim-C", seed: 203, frames: 5, gap: 1)
        add(
            "sim-decoy", jpeg(.scene(seed: 204)), date: simADate.addingTimeInterval(8),
            expected: .none, note: "Taken seconds after sim-A but a different scene: not part of it.")

        // MARK: Blurry photos

        for i in 1...4 {
            add(
                "blur-\(i)", jpeg(.scene(seed: UInt64(300 + i)), [.blur(12)]),
                expected: .blurry, note: "Out of focus.")
        }
        for i in 5...6 {
            add(
                "blur-\(i)", jpeg(.scene(seed: UInt64(300 + i)), [.blur(20)]),
                expected: .blurry, note: "Badly out of focus.")
        }
        add(
            "motion-1", jpeg(.scene(seed: 307), [.motionBlur(61)]), expected: .blurry,
            note: "Camera shake along one axis. Borderline: caught on a Mac, missed in the iOS "
                + "simulator. Reported per device, not asserted.", informational: true)
        add(
            "motion-2", jpeg(.scene(seed: 308), [.motionBlur(61)]), expected: .blurry,
            note: "Known gap: shake along one axis leaves sharp edges across it, and the blur check "
                + "does not always catch it. Reported per device, not asserted.", informational: true)

        // MARK: Screenshots (PNG tagged as a screenshot)

        for i in 1...4 {
            add(
                "shot-\(i)",
                BaselineRecipe(base: .stripes(seed: UInt64(400 + i), width: 390, height: 844), format: .png),
                kind: .screenshot, expected: .screenshots,
                note: "Phone-sized PNG tagged as a screenshot. Only checked where the system tags it.")
        }

        // MARK: Videos

        func clip(_ seed: UInt64, _ seconds: Double, _ w: Int, _ h: Int, _ bitrate: Int)
            -> BaselineRecipe
        {
            BaselineRecipe(
                base: .video(seed: seed, seconds: seconds),
                format: .mov(width: w, height: h, bitrate: bitrate))
        }
        let vTwin = nextDate()
        add(
            "vid-twin-1", clip(501, 3, 320, 240, 600_000), kind: .video, date: vTwin,
            expected: .largeVideos,
            note: "One clip, two copies. Copies of a video are not grouped: each is just a "
                + "video in the size list.")
        add(
            "vid-twin-2", clip(501, 3, 240, 180, 200_000), kind: .video,
            date: vTwin.addingTimeInterval(3600), expected: .largeVideos,
            note: "The same clip, smaller. Must still be listed on its own.")
        add(
            "vid-u1", clip(511, 2, 320, 240, 600_000), kind: .video, expected: .largeVideos,
            note: "A short video.")
        add(
            "vid-u2", clip(512, 4, 480, 360, 900_000), kind: .video, expected: .largeVideos,
            note: "A medium video.")
        add(
            "vid-u3", clip(513, 6, 640, 480, 1_200_000), kind: .video, expected: .largeVideos,
            note: "The longest, largest video: first in the size list.")

        return BaselineCatalog(
            version: version, name: "iclean baseline library", albumTitle: albumTitle, assets: assets)
    }
}
