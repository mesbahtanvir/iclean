import CleanupKit
import SwiftUI

// The colour of each category (spec 013). It is only ever the tile behind the category's glyph and
// that category's slice of the storage bar: the words carry the meaning, and no text, control or
// photo mark is drawn in it. System colours, so Dark Mode and Increase Contrast adjust them.

extension CleanupCategory {
    var tint: Color {
        switch self {
        case .duplicates: .blue
        case .similar: .indigo
        case .blurry: .orange
        case .unimportant: .gray
        case .screenshots: .teal
        case .largeVideos: .purple
        }
    }
}

/// The rounded tile with a white glyph that Settings and Files put in front of a row.
struct CategoryIcon: View {
    let category: CleanupCategory

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 30

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(
                category.tint.gradient,
                in: RoundedRectangle(cornerRadius: side / 4, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// How the selection splits by category: one slice per category in its colour, like iPhone Storage.
/// Decoration under the hero, which says the total, so VoiceOver skips it.
struct StorageBar: View {
    let perCategory: [CleanupCategory: CategoryTally]

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 10

    private struct Slice: Identifiable {
        let category: CleanupCategory
        let bytes: Int64
        var id: CleanupCategory { category }
    }

    var body: some View {
        // In the categories' fixed order, so the slices never reshuffle.
        let slices = CleanupCategory.allCases.compactMap { category -> Slice? in
            guard let tally = perCategory[category], tally.selectedBytes > 0 else { return nil }
            return Slice(category: category, bytes: tally.selectedBytes)
        }
        let total = max(1, slices.reduce(Int64(0)) { $0 + $1.bytes })
        let gap: CGFloat = 2
        GeometryReader { proxy in
            let available = proxy.size.width - gap * CGFloat(max(0, slices.count - 1))
            HStack(spacing: gap) {
                ForEach(slices) { slice in
                    Rectangle()
                        .fill(slice.category.tint.gradient)
                        .frame(width: max(4, available * CGFloat(slice.bytes) / CGFloat(total)))
                }
            }
        }
        .frame(height: height)
        .background(.fill.tertiary)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}
