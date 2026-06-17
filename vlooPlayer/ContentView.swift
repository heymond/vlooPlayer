import AVKit
import SwiftUI
import UIKit

struct ContentView: View {
    private let overlayDisplayDuration: Double = 3
    private let landscapeSectionDisplayDuration: Double = 2 //섹션선택 유지시간

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = LoopPlaybackModel()
    @State private var isShowingDocumentPicker = false
    @State private var isShowingHelpMenu = false
    @State private var isShowingHelp = false
    @State private var isShowingScriptToSRT = false
    @State private var isConfirmingCacheClear = false
    @State private var areControlsVisible = false
    @State private var areLandscapeSegmentsVisible = false
    @State private var hideControlsWorkItem: DispatchWorkItem?
    @State private var hideLandscapeSegmentsWorkItem: DispatchWorkItem?
    @State private var timelineScrubTime: Double?
    @State private var isFineWaveformVisible = false
    @State private var isFineWaveformLoading = false
    @State private var fineWaveformSamples: [FineWaveformSample] = []
    @State private var fineWaveformCenterTime: Double = 0
    @State private var fineWaveformTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            Group {
                if isLandscape {
                    landscapeLayout
                } else {
                    portraitLayout(width: geometry.size.width)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(Color.black)
            .sheet(isPresented: $isShowingDocumentPicker) {
                VideoDocumentPicker { videoURL, subtitleURL in
                    hideFineWaveform()
                    model.loadVideo(from: videoURL, subtitle: subtitleURL)
                    isShowingDocumentPicker = false
                    if isLandscape {
                        showLandscapeOverlays()
                    } else {
                        showControlsTemporarily()
                    }
                }
            }
            .sheet(isPresented: $isShowingHelpMenu) {
                HelpMenuView(
                    showHowToUse: {
                        isShowingHelpMenu = false
                        DispatchQueue.main.async {
                            isShowingHelp = true
                        }
                    },
                    showScriptToSRT: {
                        isShowingHelpMenu = false
                        DispatchQueue.main.async {
                            isShowingScriptToSRT = true
                        }
                    },
                    clearCache: {
                        isShowingHelpMenu = false
                        DispatchQueue.main.async {
                            isConfirmingCacheClear = true
                        }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingHelp) {
                HowToUseView()
            }
            .sheet(isPresented: $isShowingScriptToSRT) {
                ScriptToSRTView()
            }
            .confirmationDialog(
                "Clear all cached data?",
                isPresented: $isConfirmingCacheClear,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    model.clearCache()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the recent video, markers, sections, playback positions, and saved settings.")
            }
            .onChange(of: isLandscape) { _, landscape in
                if landscape {
                    showLandscapeOverlays()
                } else {
                    showControlsTemporarily()
                }
            }
            .task {
                await Task.yield()
                model.loadInitialVideoIfNeeded()
            }
            .onChange(of: model.isPlaying) { _, isPlaying in
                updateIdleTimer(for: isPlaying)
                if isPlaying {
                    hideFineWaveform()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    updateIdleTimer(for: model.isPlaying)
                } else {
                    updateIdleTimer(for: false)
                }
            }
            .onDisappear {
                updateIdleTimer(for: false)
            }
        }
    }

    private func portraitLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            videoSurface(isLandscape: false)
                .frame(width: width, height: width * 9 / 16)

            playbackTimeline(isLandscape: false)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(Color(.systemBackground))

            repeatSelector
                .background(Color(.systemBackground))

            transportControls(isLandscape: false)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))

            subtitleSyncControls(isLandscape: false)
                .padding(.bottom, 6)
                .background(Color(.systemBackground))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    model.toggleAllSegmentPlaybackSelections()
                } label: {
                    Image(systemName: model.areAllSegmentsPlaybackSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.areAllSegmentsPlaybackSelected ? "Disable repeat for all sections" : "Enable repeat for all sections")

                Text("Sections")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                Button {
                    model.undoLastMarkerDeletion()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndoMarkerDeletion)

                Button("Delete All", role: .destructive) {
                    model.removeAllMarkers()
                }
                .disabled(model.markers.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(Color(.systemBackground))

            ScrollViewReader { proxy in
                List {
                    ForEach(model.segments) { segment in
                        segmentRow(for: segment, compact: false)
                            .id(segment.index)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    model.removeSegments(at: IndexSet(integer: segment.index))
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(model.markers.isEmpty)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 150, for: .scrollContent)
                .background(Color(.systemBackground))
                .frame(height: 350)
                .onAppear {
                    scrollPortraitRestoredSectionIfNeeded(proxy)
                }
                .onChange(of: model.segments.count) { _, _ in
                    scrollPortraitRestoredSectionIfNeeded(proxy)
                }
                .onChange(of: model.restoredSectionScrollTarget) { _, _ in
                    scrollPortraitRestoredSectionIfNeeded(proxy)
                }
                .onChange(of: model.activeSegmentIndex) { _, activeIndex in
                    scrollPortraitSectionList(proxy, target: activeIndex)
                }
                .onChange(of: model.selectedSegmentIndex) { _, selectedIndex in
                    scrollPortraitSectionList(proxy, target: selectedIndex)
                }
                .onChange(of: model.isPlaying) { _, isPlaying in
                    guard isPlaying else { return }
                    scrollPortraitSectionList(proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func scrollPortraitSectionList(_ proxy: ScrollViewProxy, target: Int? = nil) {
        guard !model.isRestoringPlaybackPosition else { return }
        guard !model.isSuppressingRestoredSectionScroll else { return }
        guard let target = target ?? model.activeSegmentIndex,
              model.segments.indices.contains(target) else { return }

        if timelineScrubTime != nil {
            proxy.scrollTo(target, anchor: .center)
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private func scrollPortraitRestoredSectionIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = model.restoredSectionScrollTarget,
              model.segments.indices.contains(target) else { return }
        proxy.scrollTo(target, anchor: .center)
    }

    private var landscapeLayout: some View {
        videoSurface(isLandscape: true)
            .ignoresSafeArea()
    }

    private func videoSurface(isLandscape: Bool) -> some View {
        ZStack {
            FillVideoPlayer(player: model.player, fillsFrame: !isLandscape)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if isLandscape {
                        showLandscapeOverlays()
                    } else if areControlsVisible {
                        hideControls()
                    } else {
                        showControlsTemporarily()
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            handleOrientationSwipe(value.translation, isLandscape: isLandscape)
                        }
                )

            if let subtitle = model.currentSubtitle {
                Text(subtitle.text)
                    .font(.system(size: isLandscape ? 23 : 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.65), radius: 3)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            if !model.isPlaying && isFineWaveformVisible {
                VStack {
                    Spacer()
                    FineWaveformOverlay(
                        samples: fineWaveformSamples,
                        centerTime: fineWaveformCenterTime,
                        duration: model.duration,
                        isLoading: isFineWaveformLoading,
                        isLandscape: isLandscape,
                        onPreview: { seconds in
                            model.previewFineSeek(to: seconds)
                        },
                        onSelect: { seconds in
                            model.seek(to: seconds)
                            loadFineWaveform(around: seconds)
                        }
                    )
                    .padding(.horizontal, isLandscape ? 90 : 20)
                    Spacer()
                }
                .transition(.opacity)
            }

            if isLandscape && (areControlsVisible || areLandscapeSegmentsVisible) {
                Color.black.opacity(0.16)
                    .allowsHitTesting(false)

                landscapeControlsOverlay
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if !isLandscape && areControlsVisible {
                VStack {
                    playbackHeaderOverlay(isLandscape: false)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.18), value: areControlsVisible)
    }

    private func transportControls(isLandscape: Bool) -> some View {
        HStack(spacing: isLandscape ? 24 : 16) {
            Button {
                model.previousSubtitle()
                keepControlsVisible(isLandscape: isLandscape)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Previous subtitle")

            Button {
                model.togglePlayback()
                keepControlsVisible(isLandscape: isLandscape)
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: isLandscape ? 30 : 27, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Button {
                model.nextSubtitle()
                keepControlsVisible(isLandscape: isLandscape)
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .accessibilityLabel("Next subtitle")

            Button(action: {}) {
                Image(systemName: "bookmark.fill")
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1)
                    .exclusively(before: TapGesture())
                    .onEnded { value in
                        switch value {
                        case .first:
                            if model.hasSubtitles {
                                model.addAutomaticSubtitleMarkers()
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        case .second:
                            model.addMarkerAtCurrentTime()
                        }
                        keepControlsVisible(isLandscape: isLandscape)
                    }
            )
            .accessibilityLabel("Add section marker")
            .accessibilityHint("Tap to add a marker, or press and hold for one second to create markers from subtitles")

            Button {
                model.toggleSubtitles()
                keepControlsVisible(isLandscape: isLandscape)
            } label: {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(model.isSubtitleVisible && model.hasSubtitles ? Color.cyan : Color.white)
            }
            .disabled(!model.hasSubtitles)
            .opacity(model.hasSubtitles ? 1 : 0.45)
            .accessibilityLabel(model.isSubtitleVisible ? "Hide subtitles" : "Show subtitles")
        }
        .font(.system(size: isLandscape ? 24 : 22, weight: .semibold))
        .foregroundStyle(isLandscape ? Color.white : Color.primary)
        .buttonStyle(ControlPressButtonStyle(normalColor: isLandscape ? .white : .primary))
        .padding(.horizontal, isLandscape ? 32 : 24)
    }

    private func playbackTimeline(isLandscape: Bool) -> some View {
        HStack(spacing: 8) {
            Text(formattedTime(timelineScrubTime ?? model.currentTime))
            Slider(
                value: Binding(
                    get: { timelineScrubTime ?? model.currentTime },
                    set: { seconds in
                        timelineScrubTime = seconds
                        model.previewSeek(to: seconds)
                    }
                ),
                in: 0...max(model.duration, 0.1),
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    let target = timelineScrubTime ?? model.currentTime
                    timelineScrubTime = nil
                    model.seek(to: target)
                    keepControlsVisible(isLandscape: isLandscape)
                }
            )
            .tint(isLandscape ? .white : .blue)
            Text(formattedTime(model.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(isLandscape ? Color.white : Color.secondary)
    }

    private func subtitleSyncControls(isLandscape: Bool) -> some View {
        HStack(spacing: 12) {
            Text("Subtitle Sync")
                .font(.caption.weight(.semibold))

            Button {
                model.adjustSubtitleOffset(by: -0.5)
                keepControlsVisible(isLandscape: isLandscape)
            } label: {
                Label("0.5s earlier", systemImage: "minus")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Show subtitles 0.5 seconds earlier")

            Button {
                model.resetSubtitleOffset()
                keepControlsVisible(isLandscape: isLandscape)
            } label: {
                Text(formattedSubtitleOffset)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .frame(minWidth: 58)
            }
            .accessibilityLabel("Reset subtitle sync")

            Button {
                model.adjustSubtitleOffset(by: 0.5)
                keepControlsVisible(isLandscape: isLandscape)
            } label: {
                Label("0.5s later", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Show subtitles 0.5 seconds later")
        }
        .foregroundStyle(isLandscape ? Color.white : Color.primary)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.hasSubtitles)
        .opacity(model.hasSubtitles ? 1 : 0.45)
    }

    private var formattedSubtitleOffset: String {
        String(format: "%+.1fs", model.subtitleOffset)
    }

    private var repeatSelector: some View {
        HStack(spacing: 6) {
            Text("Repeat")
                .font(.headline)
                .foregroundStyle(.blue)

            Button {
                model.toggleAutoAdvanceAfterRepeat()
            } label: {
                repeatArrowButton
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue to next section after repeating")

            ForEach([1, 3, 5], id: \.self) { count in
                Button {
                    model.setRepeatOption(count)
                } label: {
                    repeatCountButton(count)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Repeat \(count) times")
            }

            Spacer()

            Button {
                toggleFineWaveform()
            } label: {
                fineWaveformButtonIcon
            }
            .buttonStyle(.plain)
            .disabled(model.videoURL == nil || model.isPlaying)
            .opacity(model.videoURL == nil || model.isPlaying ? 0.45 : 1)
            .accessibilityLabel(isFineWaveformVisible ? "Hide fine waveform" : "Show fine waveform")

            Button {
                isShowingHelpMenu = true
            } label: {
                questionButtonIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Help and cache menu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func repeatCountButton(_ count: Int) -> some View {
        let isSelected = model.repeatCount == count && !model.isInfiniteRepeat

        return ZStack {
            Image(systemName: isSelected ? "circle.fill" : "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.blue)

            Text("\(count)")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(isSelected ? Color.white : Color.blue)
        }
        .contentShape(Circle())
            .frame(width: 38, height: 38)
    }

    private var repeatArrowButton: some View {
        let isSelected = model.autoAdvanceAfterRepeat

        return ZStack {
            Image(systemName: isSelected ? "circle.fill" : "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.blue)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(isSelected ? Color.white : Color.blue)
        }
        .contentShape(Circle())
        .frame(width: 38, height: 38)
    }

    private var fineWaveformButtonIcon: some View {
        ZStack {
            Image(systemName: isFineWaveformVisible ? "circle.fill" : "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.blue)

            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(isFineWaveformVisible ? Color.white : Color.blue)
        }
        .contentShape(Circle())
        .frame(width: 38, height: 38)
    }

    private var questionButtonIcon: some View {
        ZStack {
            Image(systemName: "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.blue)

            Text("?")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(Color.blue)
        }
        .contentShape(Circle())
            .frame(width: 38, height: 38)
    }

    private var landscapeControlsOverlay: some View {
        ZStack {
            if areControlsVisible {
                VStack {
                    playbackHeaderOverlay(isLandscape: true)
                    Spacer()
                }
            }

            if areControlsVisible {
                VStack(spacing: 10) {
                    transportControls(isLandscape: true)

                    subtitleSyncControls(isLandscape: true)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 38)

                playbackTimeline(isLandscape: true)
                    .containerRelativeFrame(.horizontal) { width, _ in
                        width * 0.8
                    }
                    .offset(y: 90)
            }

            if areLandscapeSegmentsVisible {
                HStack {
                    Spacer()

                    landscapeSectionList
                        .padding(.trailing, 18)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }

    private var landscapeSectionList: some View {
        VStack(spacing: 6) {
            Text(currentSectionLabel.isEmpty ? "Sections" : currentSectionLabel)
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.segments) { segment in
                            segmentRow(for: segment, compact: true)
                                .frame(width: 100)
                                .id(segment.index)
                        }
                    }
                    .padding(.vertical, 96)
                }
                .frame(width: 100, height: 234)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in showLandscapeOverlays() }
                        .onEnded { _ in showLandscapeOverlays() }
                )
                .onAppear {
                    if let target = model.restoredSectionScrollTarget,
                       model.segments.indices.contains(target) {
                        proxy.scrollTo(target, anchor: .center)
                    } else if !model.isRestoringPlaybackPosition && !model.isSuppressingRestoredSectionScroll {
                        proxy.scrollTo(model.selectedSegmentIndex, anchor: .center)
                    }
                }
                .onChange(of: model.segments.count) { _, _ in
                    scrollLandscapeRestoredSectionIfNeeded(proxy)
                }
                .onChange(of: model.restoredSectionScrollTarget) { _, _ in
                    scrollLandscapeRestoredSectionIfNeeded(proxy)
                }
                .onChange(of: model.selectedSegmentIndex) { _, selectedIndex in
                    guard !model.isRestoringPlaybackPosition else { return }
                    guard !model.isSuppressingRestoredSectionScroll else { return }
                    if timelineScrubTime != nil {
                        proxy.scrollTo(selectedIndex, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            proxy.scrollTo(selectedIndex, anchor: .center)
                        }
                    }
                }
                .onChange(of: model.isPlaying) { _, isPlaying in
                    guard isPlaying else { return }
                    guard !model.isRestoringPlaybackPosition else { return }
                    guard !model.isSuppressingRestoredSectionScroll else { return }
                    guard let activeIndex = model.activeSegmentIndex else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }
        }
         .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.56))
        )
    }

    private func scrollLandscapeRestoredSectionIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = model.restoredSectionScrollTarget,
              model.segments.indices.contains(target) else { return }
        proxy.scrollTo(target, anchor: .center)
    }

    private func playbackHeaderOverlay(isLandscape: Bool) -> some View {
        ZStack {
            if !currentVideoFilename.isEmpty {
                Text(currentVideoFilename)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: isLandscape ? 420 : 270)
                    .background(.black.opacity(0.58), in: Capsule())
            }

            HStack {
                Spacer()

                Button {
                    isShowingDocumentPicker = true
                    if isLandscape {
                        showLandscapeOverlays()
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .controlButtonStyle()
            }
        }
        .padding(.horizontal, isLandscape ? 24 : 12)
        .padding(.top, 12)
    }

    private var currentVideoFilename: String {
        model.videoURL?.lastPathComponent ?? ""
    }

    @ViewBuilder
    private func segmentRow(for segment: LoopSegment, compact: Bool) -> some View {
        let isCurrent = model.activeSegmentIndex == segment.index

        if compact {
            Button {
                showLandscapeOverlays()
                model.playSegmentImmediately(segment)
            } label: {
                VStack(spacing: 2) {
                    Text("Section \(segment.index + 1)")
                        .font(.caption.bold())
                    Text("\(formattedTime(segment.start))-\(formattedTime(segment.end))")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(isCurrent ? Color.black : Color.white)
                .frame(width: 92)
                .frame(minHeight: 42)
                .background(isCurrent ? Color.white.opacity(0.92) : Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                Button {
                    model.toggleSegmentPlaybackSelection(segment)
                } label: {
                    Image(systemName: model.isSegmentPlaybackSelected(segment) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    model.isSegmentPlaybackSelected(segment)
                        ? "Disable repeat for Section \(segment.index + 1)"
                        : "Enable repeat for Section \(segment.index + 1)"
                )

                Button {
                    cancelControlsHide()
                    model.playSegmentImmediately(segment)
                } label: {
                    HStack {
                        Text("Section \(segment.index + 1)")
                            .font(.system(size: 16, weight: .semibold))

                        if let subtitleText = subtitlePreview(for: segment) {
                            Text(subtitleText)
                                .font(.system(size: 15)) //세로모드 섹션바 자막크기
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 0)
                        }

                        Text("\(formattedTime(segment.start)) - \(formattedTime(segment.end))")
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(minHeight: 58)
                    .background(isCurrent ? Color.gray.opacity(0.34) : Color(.systemBackground))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
        }
    }

    private func subtitlePreview(for segment: LoopSegment) -> String? {
        let targetStart = segment.start - model.subtitleOffset
        let targetEnd = segment.end - model.subtitleOffset
        var lowerBound = 0
        var upperBound = model.subtitles.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if model.subtitles[middle].start < targetStart {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        guard model.subtitles.indices.contains(lowerBound),
              model.subtitles[lowerBound].start < targetEnd else { return nil }
        return model.subtitles[lowerBound].text.replacingOccurrences(of: "\n", with: " ")
    }

    private var currentSectionLabel: String {
        guard let index = model.activeSegmentIndex else { return "" }
        return "Playing Section \(index + 1)"
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let totalSeconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func keepControlsVisible(isLandscape: Bool) {
        if isLandscape {
            showLandscapeOverlays()
        } else {
            showControlsTemporarily()
        }
    }

    private func showLandscapeOverlays() {
        areControlsVisible = true
        areLandscapeSegmentsVisible = true
        hideControlsWorkItem?.cancel()
        hideLandscapeSegmentsWorkItem?.cancel()

        let controlsItem = DispatchWorkItem {
            withAnimation {
                areControlsVisible = false
            }
        }
        hideControlsWorkItem = controlsItem
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayDisplayDuration, execute: controlsItem)

        let segmentsItem = DispatchWorkItem {
            withAnimation {
                areLandscapeSegmentsVisible = false
            }
        }
        hideLandscapeSegmentsWorkItem = segmentsItem
        DispatchQueue.main.asyncAfter(deadline: .now() + landscapeSectionDisplayDuration, execute: segmentsItem)
    }

    private func showControlsTemporarily() {
        areControlsVisible = true
        hideControlsWorkItem?.cancel()

        let item = DispatchWorkItem {
            withAnimation {
                areControlsVisible = false
            }
        }
        hideControlsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayDisplayDuration, execute: item)
    }

    private func hideControls() {
        hideControlsWorkItem?.cancel()
        withAnimation {
            areControlsVisible = false
        }
    }

    private func handleOrientationSwipe(_ translation: CGSize, isLandscape: Bool) {
        guard abs(translation.height) > abs(translation.width), abs(translation.height) >= 60 else { return }

        if !isLandscape, translation.height < 0 {
            requestOrientation(.landscape)
        } else if isLandscape, translation.height > 0 {
            requestOrientation(.portrait)
        }
    }

    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        windowScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }

    private func cancelControlsHide() {
        hideControlsWorkItem?.cancel()
        hideControlsWorkItem = nil
        hideLandscapeSegmentsWorkItem?.cancel()
        hideLandscapeSegmentsWorkItem = nil
    }

    private func toggleFineWaveform() {
        guard model.videoURL != nil, !model.isPlaying else { return }
        if isFineWaveformVisible {
            hideFineWaveform()
        } else {
            isFineWaveformVisible = true
            loadFineWaveform(around: model.currentTime)
        }
    }

    private func hideFineWaveform() {
        fineWaveformTask?.cancel()
        fineWaveformTask = nil
        isFineWaveformVisible = false
        isFineWaveformLoading = false
        fineWaveformSamples = []
    }

    private func loadFineWaveform(around seconds: Double) {
        fineWaveformTask?.cancel()
        let upperBound = model.duration > 0 ? model.duration : seconds
        let clampedSeconds = min(max(seconds, 0), max(upperBound, 0))
        fineWaveformCenterTime = clampedSeconds
        fineWaveformSamples = []
        isFineWaveformLoading = true

        fineWaveformTask = Task { @MainActor in
            let samples = await model.fineWaveformSamples(around: clampedSeconds)
            guard !Task.isCancelled else { return }
            fineWaveformCenterTime = clampedSeconds
            fineWaveformSamples = samples
            isFineWaveformLoading = false
        }
    }

    private func updateIdleTimer(for isPlaying: Bool) {
        UIApplication.shared.isIdleTimerDisabled = isPlaying
    }
}

private struct FineWaveformOverlay: View {
    let samples: [FineWaveformSample]
    let centerTime: Double
    let duration: Double
    let isLoading: Bool
    let isLandscape: Bool
    let onPreview: (Double) -> Void
    let onSelect: (Double) -> Void

    @State private var selectedTime: Double?

    private let radius = 1.0
    private let barCount = 96

    var body: some View {
        GeometryReader { geometry in
            let window = visibleWindow
            let activeTime = selectedTime ?? centerTime
            let centerX = xPosition(for: centerTime, width: geometry.size.width, window: window)
            let activeX = xPosition(for: activeTime, width: geometry.size.width, window: window)

            ZStack {
                VStack(spacing: 6) {
                    header(activeTime: activeTime)
                    ZStack {
                        HStack(alignment: .center, spacing: 1) {
                            ForEach(0..<barCount, id: \.self) { index in
                                let time = timeForBar(index, window: window)
                                let level = level(at: time)
                                Capsule()
                                    .fill(Color.cyan.opacity(level > 0 ? 0.62 : 0.18))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: max(3, CGFloat(level) * waveformHeight))
                            }
                        }

                        Rectangle()
                            .fill(Color.red.opacity(0.76))
                            .frame(width: 1.5)
                            .offset(x: centerX - geometry.size.width / 2)

                        Rectangle()
                            .fill(Color.yellow.opacity(0.76))
                            .frame(width: 1.5)
                            .offset(x: activeX - geometry.size.width / 2)
                            .opacity(selectedTime == nil ? 0 : 1)
                    }
                    .frame(height: waveformHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let target = time(at: value.location.x, width: geometry.size.width, window: window)
                                selectedTime = target
                                onPreview(target)
                            }
                            .onEnded { value in
                                let target = time(at: value.location.x, width: geometry.size.width, window: window)
                                selectedTime = nil
                                onSelect(target)
                            }
                    )
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)

                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .frame(height: isLandscape ? 82 : 76)
    }

    private var waveformHeight: CGFloat {
        isLandscape ? 51 : 45
    }

    private func header(activeTime: Double) -> some View {
        HStack {
            Text("Fine position")
            Spacer()
            Text(offsetText(for: activeTime))
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(Color.white.opacity(0.86))
    }

    private var visibleWindow: (start: Double, end: Double) {
        let safeDuration = duration > 0 ? duration : centerTime + radius
        let start = max(0, centerTime - radius)
        let end = min(max(safeDuration, centerTime + radius), centerTime + radius)
        return (start, max(start + 0.05, end))
    }

    private func timeForBar(_ index: Int, window: (start: Double, end: Double)) -> Double {
        let progress = (Double(index) + 0.5) / Double(barCount)
        return window.start + (window.end - window.start) * progress
    }

    private func time(at xPosition: CGFloat, width: CGFloat, window: (start: Double, end: Double)) -> Double {
        guard width > 0 else { return centerTime }
        let progress = min(max(Double(xPosition / width), 0), 1)
        return window.start + (window.end - window.start) * progress
    }

    private func xPosition(for time: Double, width: CGFloat, window: (start: Double, end: Double)) -> CGFloat {
        guard window.end > window.start else { return width / 2 }
        let progress = min(max((time - window.start) / (window.end - window.start), 0), 1)
        return CGFloat(progress) * width
    }

    private func level(at time: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let insertionIndex = insertionIndex(for: time)
        let candidateIndexes = [insertionIndex - 1, insertionIndex, insertionIndex + 1]

        var nearestLevel = 0.0
        var nearestDistance = Double.greatestFiniteMagnitude
        for index in candidateIndexes where samples.indices.contains(index) {
            let sample = samples[index]
            let distance = abs(sample.time - time)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestLevel = sample.level
            }
        }
        return nearestLevel
    }

    private func insertionIndex(for time: Double) -> Int {
        var lowerBound = 0
        var upperBound = samples.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if samples[middle].time < time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func offsetText(for time: Double) -> String {
        let offset = time - centerTime
        return String(format: "%+.2fs", offset)
    }
}

private struct HelpMenuView: View {
    @Environment(\.dismiss) private var dismiss

    let showHowToUse: () -> Void
    let showScriptToSRT: () -> Void
    let clearCache: () -> Void

    var body: some View {
        NavigationStack {
            List {
                menuButton(
                    title: "How to use?",
                    detail: "Learn playback, sections, repeat, and subtitle controls.",
                    systemImage: "questionmark.circle.fill",
                    action: showHowToUse
                )

                menuButton(
                    title: "Script to SRT",
                    detail: "Load an available YouTube script and export an SRT file.",
                    systemImage: "captions.bubble.fill",
                    action: showScriptToSRT
                )

                menuButton(
                    title: "Clear Cache",
                    detail: "Remove recent files, sections, positions, and saved settings.",
                    systemImage: "trash.fill",
                    role: .destructive,
                    action: clearCache
                )
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Help & Tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func menuButton(
        title: String,
        detail: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HowToUseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                helpRow("Choose a video", "Tap the folder button and select a video. SRT, SMI, or VTT subtitles with the same filename are loaded automatically. The most recent video and playback position are restored when the app opens.")
                helpRow("Show controls", "Tap the video to show the filename, playback controls, and timeline. Controls hide automatically after 3 seconds. In landscape, the section panel remains visible for 2 seconds after the last interaction.")
                helpRow("Change orientation", "Swipe up on the video in portrait mode to switch to full-screen landscape. Swipe down in landscape mode to return to portrait.")
                helpRow("Create sections", "Tap the bookmark button to add a marker at the current time. Press and hold the same button for at least 1 second to automatically create markers whenever the subtitle dialogue changes.")
                helpRow("Play sections", "Tap any section row to stop the current section and play the selected section immediately. The active section is centered automatically in portrait and landscape lists.")
                helpRow("Section repeat checks", "A filled circular check means that section uses the selected repeat count. An empty circle means the section plays once without repeating, then continues normally. Use the circle beside Sections to enable or disable repeating for every section.")
                helpRow("Repeat and continue", "Choose 1, 3, or 5 with the numbered repeat button. Enable the arrow to continue to the next section after the current section finishes its repeats. Disable the arrow to stop after the section. The infinity button repeats continuously. Sections without subtitles never repeat.")
                helpRow("Delete and undo", "Swipe a section left to delete its marker. Tap Delete All to remove every marker, or use Undo to restore recent individual or bulk deletions.")
                helpRow("Subtitles", "Use the previous and next buttons to move between subtitle cues, including while paused. Tap the captions icon to show or hide subtitles. Use Subtitle Sync to shift subtitles earlier or later in 0.5-second steps.")
                helpRow("Landscape controls", "Tap the landscape video to show centered controls, the timeline, and the vertically scrolling section panel on the right. Selecting a section scrolls it to the center of the panel.")
                helpRow("Background playback", "Audio continues when the app is in the background and playback controls appear on the Lock Screen. Other media audio may pause while the video is playing; phone calls still interrupt playback.")
                helpRow("Clear cache", "Open the question mark menu and choose Clear Cache to remove recent files, subtitles, markers, sections, playback positions, and saved settings.")
            }
            .navigationTitle("How to use")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func helpRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct FillVideoPlayer: UIViewRepresentable {
    let player: AVPlayer
    let fillsFrame: Bool
    private var cropScale: CGFloat {
        fillsFrame ? 1.45 : 1
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        view.cropScale = cropScale
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        uiView.cropScale = cropScale
    }
}

private final class PlayerLayerView: UIView {
    let playerLayer = AVPlayerLayer()

    var cropScale: CGFloat = 1 {
        didSet {
            updatePlayerLayerFrame()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        clipsToBounds = true
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
        clipsToBounds = true
        layer.masksToBounds = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePlayerLayerFrame()
    }

    private func updatePlayerLayerFrame() {
        let scale = max(cropScale, 1)
        let scaledWidth = bounds.width * scale
        let scaledHeight = bounds.height * scale
        playerLayer.frame = CGRect(
            x: (bounds.width - scaledWidth) / 2,
            y: (bounds.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
    }
}

private extension View {
    func controlButtonStyle() -> some View {
        self
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.black.opacity(0.52), in: Circle())
            .buttonStyle(ControlPressButtonStyle())
    }
}

private struct ControlPressButtonStyle: ButtonStyle {
    let normalColor: Color

    init(normalColor: Color = .white) {
        self.normalColor = normalColor
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 48, minHeight: 48)
            .contentShape(Rectangle())
            .foregroundStyle(configuration.isPressed ? Color.white : normalColor)
            .background(
                Circle()
                    .fill(configuration.isPressed ? Color.cyan.opacity(0.9) : Color.clear)
                    .frame(width: 46, height: 46)
            )
            .scaleEffect(configuration.isPressed ? 0.82 : 1)
            .brightness(configuration.isPressed ? 0.16 : 0)
            .shadow(
                color: configuration.isPressed ? Color.cyan.opacity(0.75) : Color.clear,
                radius: configuration.isPressed ? 8 : 0
            )
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}
