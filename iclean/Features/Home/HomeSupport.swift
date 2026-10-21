import CleanupKit
import Foundation

/// How a size is said aloud: "36 megabytes", not "36 MB".
enum SpokenBytes {
    static func string(_ bytes: Int64) -> String {
        let value = Double(bytes)
        let unit: UnitInformationStorage
        let scale: Double
        switch value {
        case ..<1_000: (unit, scale) = (.bytes, 1)
        case ..<1_000_000: (unit, scale) = (.kilobytes, 1_000)
        case ..<1_000_000_000: (unit, scale) = (.megabytes, 1_000_000)
        case ..<1_000_000_000_000: (unit, scale) = (.gigabytes, 1_000_000_000)
        default: (unit, scale) = (.terabytes, 1_000_000_000_000)
        }
        return Measurement(value: value / scale, unit: unit).formatted(
            .measurement(
                width: .wide, usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// "about 36 megabytes" when the size is an estimate.
    static func string(_ bytes: Int64, estimate: Bool) -> String {
        let text = string(bytes)
        return estimate ? String(localized: "about \(text)") : text
    }
}

extension String {
    /// A sentence whose count and noun agree ("1 item", "12 items"): the system applies the grammar
    /// agreement of `AttributedString(localized: "^[\(n) item](inflect: true)")`, which a plain
    /// `String(localized:)` does not.
    init(agreeing text: AttributedString) {
        self = String(text.characters)
    }
}

/// Which of Home's screens to show. One answer, resolved in this order (spec 009, amendment 0.2):
/// launching, failed, scanning or finishing, building, results, interrupted with nothing found,
/// first run, empty library, all cleaned, clean. Reads only cheap facts: nothing here touches a
/// photo, and nothing reads the scan's progress.
enum HomeState: Equatable {
    /// Opening the saved data (`opening`) or building the results from scratch.
    case launching(opening: Bool)
    /// The saved data could not be read. Never "nothing to clean up".
    case failed
    /// The list: a scan is running or finishing, results are being built, or something was found.
    case results
    case interruptedEmpty
    /// No full scan has finished yet.
    case firstRun
    /// A full scan finished and the library holds no photos or videos.
    case emptyLibrary
    case allCleaned
    case clean

    @MainActor
    init(_ model: AppModel) {
        switch model.launchPhase {
        case .opening:
            self = .launching(opening: true)
        case .building:
            self = .launching(opening: false)
        case .failed:
            self = .failed
        case .ready:
            if model.isScanning || model.isFinishing || model.isBuildingResults
                || !model.results.categories.isEmpty
            {
                self = .results
            } else if model.hasInterruptedScan {
                self = .interruptedEmpty
            } else if !model.hasFinishedFullScan {
                self = .firstRun
            } else if model.libraryItemCount == 0 {
                self = .emptyLibrary
            } else if model.hasRemovedThisSession {
                self = .allCleaned
            } else {
                self = .clean
            }
        }
    }
}
