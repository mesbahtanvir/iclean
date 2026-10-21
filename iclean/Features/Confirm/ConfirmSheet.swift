import CleanupKit
import SwiftUI

/// The one summary before anything is removed (FR-012, FR-016): how much goes, that it goes to
/// Recently Deleted, that it can come back. Then the receipt, in the same sheet.
///
/// Presented by Home and by a category; nothing is removed without it, and Return never confirms.
struct ConfirmSheet: View {
    /// Only this category's selection, or everything when nil.
    var category: CleanupCategory?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
        @Environment(\.verticalSizeClass) private var verticalSizeClass
        /// Nil until the receipt asks for the large detent; until then the opening detent is used,
        /// decided from what is known before the plan arrives, so nothing moves when it does.
        @State private var chosenDetent: PresentationDetent?
        @State private var opening = DetentLatch()
    #endif
    @State private var confirmWholeGroups = false
    @State private var isRemoving = false
    @State private var summary: CleanupSummary?
    /// What the removal will do, checked against the library when the sheet opened, with its preview
    /// worked out once.
    @State private var loaded: LoadedPlan?

    var body: some View {
        container
            .interactiveDismissDisabled(isRemoving)
            .task {
                model.removalError = nil
                let plan = await model.makeRemovalPlan(category: category)
                let remover = model.environment.remover
                // One pass over the plan, off the main thread: at 30,000 photos it is not instant.
                loaded = await Task.detached(priority: .userInitiated) {
                    LoadedPlan.make(plan, remover: remover)
                }.value
            }
            .onChange(of: model.removalError) { _, error in
                // Said once, as it appears; the note itself is not a live region.
                if let error { AccessibilityNotification.Announcement(error).post() }
            }
            .onChange(of: summary) { _, receipt in
                #if os(iOS)
                    if receipt != nil { chosenDetent = .large }
                #endif
            }
            #if os(macOS)
                // The menu commands wait while this question is up.
                .tracksSheet()
            #endif
    }

    private var isReceipt: Bool { summary.map { !$0.cancelled } ?? false }

    // MARK: Platform chrome

    #if os(iOS)
        private var container: some View {
            NavigationStack {
                state
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // Cancel in every state, the checking one included; the receipt has its own
                        // Done button and no bar at all.
                        if !isReceipt {
                            ToolbarItem(placement: .cancellationAction) { cancelButton }
                        }
                    }
                    .toolbar(isReceipt ? .hidden : .visible, for: .navigationBar)
            }
            // The detents are the same in every state; only the opening one depends on the text
            // size and the screen, and the receipt moves to the large one.
            .presentationDetents([.medium, .large], selection: detent)
            .presentationDragIndicator(.visible)
        }

        private var detent: Binding<PresentationDetent> {
            Binding(
                get: {
                    // Big text always gets the tall sheet, also if the size changes while it is open;
                    // the rest is decided once, when the sheet opens.
                    chosenDetent
                        ?? (typeSize.isAccessibilitySize
                            ? .large : opening.detent(else: openingDetent))
                },
                set: { chosenDetent = $0 })
        }

        /// Large where the half-height sheet cannot hold the question: a short screen, or a selection
        /// that includes photos meant to stay (so the whole-groups callout is likely). Known from the
        /// cached summary before the plan arrives, never from the plan itself.
        private var openingDetent: PresentationDetent {
            verticalSizeClass == .compact || mayNeedRoom ? .large : .medium
        }

        private var mayNeedRoom: Bool {
            let tallies =
                category.map { [model.summary.perCategory[$0]].compactMap { $0 } }
                ?? Array(model.summary.perCategory.values)
            return tallies.contains { $0.selected > $0.selectedRemovable }
        }

        /// Empty while checking and on the receipt; the question once the plan is known.
        private var title: Text {
            guard !isReceipt, let loaded else { return Text(verbatim: "") }
            return question(loaded)
        }
    #else
        private var container: some View {
            // A sheet on the Mac has no title bar and no size of its own.
            state
                .frame(width: Layout.macSheet)
                .frame(minHeight: 360)
                .presentationSizing(.form)
        }
    #endif

    // MARK: States

    @ViewBuilder private var state: some View {
        if let summary, !summary.cancelled {
            DoneView(summary: summary) { dismiss() }
        } else if let loaded {
            confirmation(loaded)
        } else {
            checking
        }
    }

    /// Before the plan is known: Cancel is already there, the spinner only if it takes a moment.
    private var checking: some View {
        VStack(spacing: Space.l) {
            #if os(macOS)
                Spacer(minLength: 0)
            #endif
            DelayedProgress(caption: "Checking your selection")
                .accessibilityIdentifier("confirm.checking")
            #if os(macOS)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    cancelButton
                }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
            .padding(Space.xl)
            .frame(minHeight: 200)
        #endif
    }

    private func confirmation(_ loaded: LoadedPlan) -> some View {
        let big = typeSize.isAccessibilitySize
        let preview = loaded.preview
        let blocked = !preview.wholeGroupsSelected.isEmpty && !confirmWholeGroups
        let content = ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                #if os(macOS)
                    question(loaded)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                #endif
                if preview.count > 0 {
                    VStack(alignment: .leading, spacing: Space.m) {
                        ConfirmHero(bytes: preview.bytes, count: preview.count, noun: loaded.noun)
                        ConfirmReassurance()
                    }
                } else {
                    Text("Nothing is left to remove.")
                        .font(.headline)
                }
                if !preview.wholeGroupsSelected.isEmpty {
                    WholeGroupsCallout(
                        sets: preview.wholeGroupsSelected.count, confirmed: $confirmWholeGroups)
                }
                if !big, !loaded.strip.isEmpty {
                    PhotoStrip(ids: loaded.strip, total: preview.count)
                }
                if loaded.categories.count >= 2 {
                    ConfirmCategoryRows(categories: loaded.categories, preview: preview)
                }
                if loaded.plan.droppedCount > 0 { dropped(loaded.plan.droppedCount) }
                if big {
                    // The pinned area stays one button tall; what would sit under it scrolls instead.
                    if let error = model.removalError { errorNote(error) }
                    footnote(blocked: blocked)
                }
            }
            .padding(.horizontal, platformGutter)
            .padding(.top, Space.s)
            .padding(.bottom, Space.l)
        }
        #if os(iOS)
            return content.pinnedBar(isPresented: true) {
                VStack(spacing: Space.s) {
                    if !big, let error = model.removalError { errorNote(error) }
                    removeButton(loaded, blocked: blocked)
                    if !big { footnote(blocked: blocked) }
                }
            }
        #else
            return VStack(spacing: 0) {
                content
                Divider()
                if let error = model.removalError {
                    errorNote(error).padding([.horizontal, .top], Space.xl)
                }
                HStack {
                    Spacer()
                    cancelButton
                    removeButton(loaded, blocked: blocked)
                }
                .padding(Space.xl)
            }
        #endif
    }

    private var platformGutter: CGFloat {
        #if os(macOS)
            Space.xl
        #else
            Space.l
        #endif
    }

    // MARK: Words

    private func question(_ loaded: LoadedPlan) -> Text {
        let count = loaded.preview.count
        if count == 0 { return Text("Nothing to Remove") }
        return switch loaded.noun {
        case .photos: Text("Remove \(count) Photos?")
        case .videos: Text("Remove \(count) Videos?")
        case .items: Text("Remove \(count) Items?")
        }
    }

    private func buttonTitle(_ loaded: LoadedPlan) -> Text {
        let count = loaded.preview.count
        if count == 0 { return Text("Nothing to Remove") }
        return switch loaded.noun {
        case .photos: Text("Move \(count) Photos to Recently Deleted")
        case .videos: Text("Move \(count) Videos to Recently Deleted")
        case .items: Text("Move \(count) Items to Recently Deleted")
        }
    }

    private func dropped(_ count: Int) -> some View {
        Text(
            "\(count) items were left out because they changed since the scan (deleted, edited, favorited or no longer suggested). They stay in your library."
        )
        .font(Typography.note)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("confirm.dropped")
    }

    /// Why nothing was removed. In the primary colour because it asks the person to do something
    /// (try again); the glyph is the secondary one every notice uses.
    private func errorNote(_ message: String) -> some View {
        Label {
            Text(message)
                .font(Typography.note)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
                .font(Typography.note)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("confirm.error")
    }

    /// Under the button: what the system will ask next, or why the button is off.
    private func footnote(blocked: Bool) -> some View {
        Group {
            if blocked {
                Text("Turn on “Remove them all anyway” to continue.")
            } else {
                #if os(macOS)
                    Text("Photos will ask you to confirm once more.")
                #else
                    Text(
                        "You’ll be asked to confirm once more. The system message says “Delete”, but nothing is erased yet."
                    )
                #endif
            }
        }
        .font(Typography.note)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("confirm.footnote")
    }

    // MARK: Buttons

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { dismiss() }
            #if os(macOS)
                .keyboardShortcut(.cancelAction)
            #endif
            .disabled(isRemoving)
            .accessibilityIdentifier("confirm.cancel")
    }

    private func removeButton(_ loaded: LoadedPlan, blocked: Bool) -> some View {
        let enabled = !blocked && loaded.preview.count > 0
        return Button {
            remove(loaded)
        } label: {
            Group {
                if isRemoving {
                    HStack(spacing: Space.s) {
                        ProgressView()
                        Text("Moving…")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Removing"))
                } else {
                    buttonTitle(loaded)
                        .multilineTextAlignment(.center)
                }
            }
            .font(.headline)
            #if os(iOS)
                .frame(maxWidth: .infinity)
            #endif
        }
        // The accent, not red: the photos can be put back for at least 30 days and the system asks
        // again. A switched-off primary turns into a quiet bordered button, never a faded slab.
        .modifier(PrimaryOrQuiet(prominent: enabled || isRemoving))
        #if os(iOS)
            .controlSize(.large)
        #endif
        // A capsule turns into a blob when the label wraps to four lines.
        .buttonBorderShape(
            typeSize.isAccessibilitySize ? .roundedRectangle(radius: Radius.card) : .capsule
        )
        .disabled(!enabled || isRemoving)
        .accessibilityHint(
            blocked
                ? Text("Turn on “Remove them all anyway” to continue.")
                : Text("Moves the items to Recently Deleted")
        )
        .accessibilityIdentifier("confirm.remove")
    }

    private func remove(_ loaded: LoadedPlan) {
        Task {
            isRemoving = true
            summary = await model.remove(loaded.plan, confirmRemoveAll: confirmWholeGroups)
            isRemoving = false
            if summary?.cancelled == true { dismiss() }
        }
    }
}

/// The filled capsule when the button can be pressed, a plain bordered one when it cannot.
private struct PrimaryOrQuiet: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

#if os(iOS)
    /// Remembers the detent the sheet opened at, so it is decided once and a later change in what the
    /// summary says cannot move the sheet.
    @MainActor
    final class DetentLatch {
        private var value: PresentationDetent?

        func detent(else candidate: @autoclosure () -> PresentationDetent) -> PresentationDetent {
            if let value { return value }
            let chosen = candidate()
            value = chosen
            return chosen
        }
    }
#endif
