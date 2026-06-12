import AVFoundation
import Combine
import Foundation
import MediaPlayer

struct LoopSegment: Identifiable, Equatable {
    let index: Int
    let start: Double
    let end: Double

    var id: String {
        "\(index)-\(start)-\(end)"
    }

    var duration: Double {
        max(0, end - start)
    }
}

@MainActor
final class LoopPlaybackModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var videoURL: URL?
    @Published var duration: Double = 0 {
        didSet { rebuildSegments() }
    }
    @Published var currentTime: Double = 0
    @Published var markers: [Double] = [] {
        didSet { rebuildSegments() }
    }
    @Published private(set) var segments: [LoopSegment] = []
    @Published var selectedSegmentIndex: Int = 0
    @Published var repeatCount: Int = 0
    @Published private(set) var lastFiniteRepeatCount: Int = 1
    @Published var isInfiniteRepeat: Bool = false
    @Published var autoAdvanceAfterRepeat: Bool = true
    @Published var completedRepeats: Int = 0
    @Published var isPlaying: Bool = false {
        didSet { updateNowPlayingInfo() }
    }
    @Published var subtitles: [SubtitleCue] = []
    @Published var isSubtitleVisible: Bool = true
    @Published var subtitleURL: URL?
    @Published var subtitleOffset: Double = 0
    @Published private(set) var canUndoMarkerDeletion = false
    @Published private(set) var excludedSegmentStarts: Set<Double> = []

    private var timeObserver: Any?
    private var durationObservation: NSKeyValueObservation?
    private var hasAccessedSecurityScopedResource = false
    private var hasAccessedSubtitleSecurityScopedResource = false
    private var playbackRevision: Int = 0
    private var isTransitioningSegment = false
    private var remoteCommandTargets: [Any] = []
    private var lastNowPlayingUpdateSecond: Int = -1
    private var markerDeletionHistory: [[Double]] = []

    private enum RecentFileKey {
        static let videoBookmark = "recentVideoBookmark"
        static let subtitleBookmark = "recentSubtitleBookmark"
    }

    private enum PlaybackSettingKey {
        static let repeatCount = "lastRepeatCount"
        static let finiteRepeatCount = "lastFiniteRepeatCount"
        static let isInfiniteRepeat = "lastInfiniteRepeat"
        static let autoAdvanceAfterRepeat = "autoAdvanceAfterRepeat"
    }

    private struct PersistedPlaybackState: Codable {
        let markers: [Double]
        let selectedSegmentIndex: Int
        let currentTime: Double
        let repeatCount: Int
        let isInfiniteRepeat: Bool
        let autoAdvanceAfterRepeat: Bool?
        let excludedSegmentStarts: [Double]?
        let isSubtitleVisible: Bool
        let subtitleOffset: Double?
    }

    private func rebuildSegments() {
        let points = normalizedBoundaryPoints
        guard points.count >= 2 else {
            segments = []
            return
        }

        let boundaries = zip(points.dropLast(), points.dropFirst())
            .filter { start, end in end - start > 0.1 }

        // Reindex after removing tiny ranges. Segment indices are also used as
        // array positions throughout playback and must always remain contiguous.
        segments = boundaries.enumerated().map { index, boundary in
            LoopSegment(index: index, start: boundary.0, end: boundary.1)
        }
    }

    var selectedSegment: LoopSegment? {
        guard segments.indices.contains(selectedSegmentIndex) else { return segments.first }
        return segments[selectedSegmentIndex]
    }

    var areAllSegmentsPlaybackSelected: Bool {
        !segments.isEmpty && segments.allSatisfy(isSegmentPlaybackSelected(_:))
    }

    func isSegmentPlaybackSelected(_ segment: LoopSegment) -> Bool {
        !excludedSegmentStarts.contains(where: { abs($0 - segment.start) < 0.01 })
    }

    func toggleSegmentPlaybackSelection(_ segment: LoopSegment) {
        if let excludedStart = excludedSegmentStarts.first(where: { abs($0 - segment.start) < 0.01 }) {
            excludedSegmentStarts.remove(excludedStart)
        } else {
            excludedSegmentStarts.insert(segment.start)
        }
        savePlaybackState()
    }

    func toggleAllSegmentPlaybackSelections() {
        if areAllSegmentsPlaybackSelected {
            excludedSegmentStarts = Set(segments.map(\.start))
        } else {
            excludedSegmentStarts.removeAll()
        }
        savePlaybackState()
    }

    var canRepeatSegment: Bool {
        selectedSegment != nil
    }

    var effectiveRepeatLabel: String {
        if isInfiniteRepeat { return "∞" }
        return repeatCount == 0 ? "0" : "\(repeatCount)"
    }

    var repeatOptions: [Int] {
        [0, 1, 3, 5]
    }

    var repeatAccessibilityLabel: String {
        if isInfiniteRepeat { return "Repeat forever" }
        if repeatCount == 0 { return "Continue playback" }
        return "Repeat \(repeatCount) times"
    }

    var finiteRepeatDisplayCount: Int {
        [1, 3, 5].contains(repeatCount) ? repeatCount : lastFiniteRepeatCount
    }

    var targetPlaybackCount: Int {
        max(1, repeatCount)
    }

    var currentSubtitle: SubtitleCue? {
        guard isSubtitleVisible else { return nil }
        guard let index = subtitleIndex(at: currentTime) else { return nil }
        return subtitles[index]
    }

    var hasSubtitles: Bool {
        !subtitles.isEmpty
    }

    var activeSegmentIndex: Int? {
        if repeatCount > 0 || isInfiniteRepeat {
            return segments.indices.contains(selectedSegmentIndex) ? selectedSegmentIndex : segments.indices.first
        }

        return segmentIndex(at: currentTime)
            ?? (currentTime >= duration && !segments.isEmpty ? segments.indices.last : nil)
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        configureRemoteCommands()
        installTimeObserver()
        restoreRepeatSetting()
        loadRecentVideoIfAvailable()
    }

    func loadVideo(from url: URL, subtitle explicitSubtitleURL: URL? = nil, remember: Bool = true) {
        if hasAccessedSecurityScopedResource {
            videoURL?.stopAccessingSecurityScopedResource()
            hasAccessedSecurityScopedResource = false
        }
        if hasAccessedSubtitleSecurityScopedResource {
            subtitleURL?.stopAccessingSecurityScopedResource()
            hasAccessedSubtitleSecurityScopedResource = false
        }

        hasAccessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
        videoURL = url
        markers = []
        excludedSegmentStarts = []
        markerDeletionHistory = []
        canUndoMarkerDeletion = false
        subtitles = []
        subtitleURL = nil
        subtitleOffset = 0
        isSubtitleVisible = true
        selectedSegmentIndex = 0
        completedRepeats = 0
        isTransitioningSegment = false
        currentTime = 0
        duration = 0

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        updateNowPlayingInfo()
        if let explicitSubtitleURL {
            loadSubtitle(from: explicitSubtitleURL)
        } else {
            loadMatchingSubtitle(for: url)
        }
        restorePlaybackState(for: url)
        observeDuration(for: item)

        if remember {
            rememberRecentVideo(url, subtitle: explicitSubtitleURL)
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if let segment = selectedSegment, currentTime < segment.start || currentTime >= segment.end {
                startSegmentPlayback(segment)
                isPlaying = true
                return
            }
            player.play()
        }
        isPlaying.toggle()
    }

    func addMarkerAtCurrentTime() {
        addMarker(at: currentTime)
    }

    func addAutomaticSubtitleMarkers() {
        guard duration > 0, !subtitles.isEmpty else { return }

        var previousDialogue: String?
        var automaticMarkers: [Double] = []

        for subtitle in subtitles {
            let dialogue = subtitle.text
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")

            guard !dialogue.isEmpty, dialogue != previousDialogue else { continue }
            previousDialogue = dialogue

            let markerTime = min(max(subtitle.start + subtitleOffset, 0), duration)
            guard markerTime > 0.05, markerTime < duration - 0.05 else { continue }
            guard !automaticMarkers.contains(where: { abs($0 - markerTime) < 0.25 }) else { continue }
            automaticMarkers.append(markerTime)
        }

        guard !automaticMarkers.isEmpty else { return }
        var updatedMarkers = markers
        updatedMarkers.append(contentsOf: automaticMarkers.filter { marker in
            !markers.contains(where: { abs($0 - marker) < 0.25 })
        })
        markers = updatedMarkers.sorted()
        syncSelectedSegmentToCurrentTime()
        savePlaybackState()
    }

    func addMarker(at time: Double) {
        guard duration > 0 else { return }
        let clampedTime = min(max(time, 0), duration)
        let tolerance = 0.25
        guard !markers.contains(where: { abs($0 - clampedTime) < tolerance }) else { return }

        playbackRevision += 1
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        isTransitioningSegment = false
        completedRepeats = 0
        markers = (markers + [clampedTime]).sorted()
        syncSelectedSegmentToCurrentTime()
        savePlaybackState()
    }

    func removeMarker(_ marker: Double) {
        let removedMarkers = markers.filter { abs($0 - marker) < 0.01 }
        guard !removedMarkers.isEmpty else { return }
        recordMarkerDeletion(removedMarkers)
        markers.removeAll { candidate in
            removedMarkers.contains(where: { abs($0 - candidate) < 0.01 })
        }
        syncSelectedSegmentToCurrentTime()
        savePlaybackState()
    }

    func removeSegments(at offsets: IndexSet) {
        let currentSegments = segments
        let markersToRemove = offsets.compactMap { offset -> Double? in
            guard currentSegments.indices.contains(offset) else { return nil }
            let segment = currentSegments[offset]
            return segment.index == 0 ? markerMatching(segment.end) : markerMatching(segment.start)
        }

        guard !markersToRemove.isEmpty else { return }
        recordMarkerDeletion(markersToRemove)
        markers.removeAll { marker in
            markersToRemove.contains(where: { abs($0 - marker) < 0.01 })
        }
        syncSelectedSegmentToCurrentTime()
        savePlaybackState()
    }

    func removeAllMarkers() {
        guard !markers.isEmpty else { return }
        recordMarkerDeletion(markers)
        markers.removeAll()
        selectedSegmentIndex = 0
        completedRepeats = 0
        isTransitioningSegment = false
        savePlaybackState()
    }

    func undoLastMarkerDeletion() {
        guard let deletedMarkers = markerDeletionHistory.popLast() else { return }
        var restoredMarkers = markers
        restoredMarkers.append(contentsOf: deletedMarkers.filter { deletedMarker in
            !markers.contains(where: { abs($0 - deletedMarker) < 0.01 })
        })
        markers = restoredMarkers.sorted()
        canUndoMarkerDeletion = !markerDeletionHistory.isEmpty
        syncSelectedSegmentToCurrentTime()
        savePlaybackState()
    }

    private func recordMarkerDeletion(_ deletedMarkers: [Double]) {
        guard !deletedMarkers.isEmpty else { return }
        markerDeletionHistory.append(deletedMarkers)
        if markerDeletionHistory.count > 20 {
            markerDeletionHistory.removeFirst()
        }
        canUndoMarkerDeletion = true
    }

    func clearCache() {
        playbackRevision += 1
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        player.replaceCurrentItem(with: nil)

        if hasAccessedSecurityScopedResource {
            videoURL?.stopAccessingSecurityScopedResource()
            hasAccessedSecurityScopedResource = false
        }
        if hasAccessedSubtitleSecurityScopedResource {
            subtitleURL?.stopAccessingSecurityScopedResource()
            hasAccessedSubtitleSecurityScopedResource = false
        }

        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where
            key.hasPrefix("playbackState.") ||
            key == RecentFileKey.videoBookmark ||
            key == RecentFileKey.subtitleBookmark ||
            key == PlaybackSettingKey.repeatCount ||
            key == PlaybackSettingKey.finiteRepeatCount ||
            key == PlaybackSettingKey.isInfiniteRepeat ||
            key == PlaybackSettingKey.autoAdvanceAfterRepeat {
            defaults.removeObject(forKey: key)
        }

        videoURL = nil
        subtitleURL = nil
        duration = 0
        currentTime = 0
        markers = []
        excludedSegmentStarts = []
        markerDeletionHistory = []
        canUndoMarkerDeletion = false
        subtitles = []
        subtitleOffset = 0
        selectedSegmentIndex = 0
        repeatCount = 0
        lastFiniteRepeatCount = 1
        isInfiniteRepeat = false
        autoAdvanceAfterRepeat = true
        completedRepeats = 0
        isPlaying = false
        isSubtitleVisible = true
        isTransitioningSegment = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func selectSegment(_ segment: LoopSegment) {
        selectedSegmentIndex = segment.index
        completedRepeats = 0
        isTransitioningSegment = false
        seek(to: segment.start)
    }

    func playSegmentImmediately(_ segment: LoopSegment) {
        guard let latestSegment = segments.first(where: {
            abs($0.start - segment.start) < 0.01 && abs($0.end - segment.end) < 0.01
        }) else { return }

        let revision = beginPlaybackTransition()
        selectedSegmentIndex = latestSegment.index
        currentTime = latestSegment.start
        savePlaybackState()
        seekAndPlay(latestSegment, revision: revision, startsNewPlayback: true)
    }

    func previousSegment() {
        guard !segments.isEmpty else { return }
        selectedSegmentIndex = max(selectedSegmentIndex - 1, 0)
        completedRepeats = 0
        isTransitioningSegment = false
        seek(to: segments[selectedSegmentIndex].start)
    }

    func nextSegment() {
        guard !segments.isEmpty else { return }
        selectedSegmentIndex = min(selectedSegmentIndex + 1, segments.count - 1)
        completedRepeats = 0
        isTransitioningSegment = false
        seek(to: segments[selectedSegmentIndex].start)
    }

    func previousSubtitle() {
        guard !subtitles.isEmpty else { return }
        let currentIndex = subtitleIndex(at: currentTime)
        let targetIndex: Int

        if let currentIndex {
            targetIndex = max(currentIndex - 1, 0)
        } else {
            targetIndex = subtitles.lastIndex(where: { $0.start < currentTime }) ?? 0
        }
        seekToSubtitle(at: targetIndex)
    }

    func nextSubtitle() {
        guard !subtitles.isEmpty else { return }
        let currentIndex = subtitleIndex(at: currentTime)
        let targetIndex: Int

        if let currentIndex {
            targetIndex = min(currentIndex + 1, subtitles.count - 1)
        } else {
            targetIndex = subtitles.firstIndex(where: { $0.start > currentTime }) ?? (subtitles.count - 1)
        }
        seekToSubtitle(at: targetIndex)
    }

    func toggleSubtitles() {
        isSubtitleVisible.toggle()
        savePlaybackState()
    }

    func adjustSubtitleOffset(by seconds: Double) {
        subtitleOffset = min(max(subtitleOffset + seconds, -10), 10)
        subtitleOffset = (subtitleOffset * 10).rounded() / 10
        savePlaybackState()
    }

    func resetSubtitleOffset() {
        subtitleOffset = 0
        savePlaybackState()
    }

    func setRepeatOption(_ count: Int) {
        repeatCount = count
        if [1, 3, 5].contains(count) {
            lastFiniteRepeatCount = count
        }
        isInfiniteRepeat = false
        completedRepeats = 0
        isTransitioningSegment = false
        saveRepeatSetting()
        savePlaybackState()
    }

    func toggleAutoAdvanceAfterRepeat() {
        autoAdvanceAfterRepeat.toggle()
        saveRepeatSetting()
        savePlaybackState()
    }

    func setInfiniteRepeat() {
        isInfiniteRepeat = true
        completedRepeats = 0
        isTransitioningSegment = false
        saveRepeatSetting()
        savePlaybackState()
    }

    func cycleRepeatOption() {
        if isInfiniteRepeat {
            setRepeatOption(0)
            return
        }

        switch repeatCount {
        case 0:
            setRepeatOption(1)
        case 1:
            setRepeatOption(3)
        case 3:
            setRepeatOption(5)
        case 5:
            setInfiniteRepeat()
        default:
            setRepeatOption(0)
        }
    }

    func cycleFiniteRepeatOption() {
        guard !isInfiniteRepeat, repeatCount > 0 else {
            setRepeatOption(lastFiniteRepeatCount)
            return
        }

        switch finiteRepeatDisplayCount {
        case 1:
            setRepeatOption(3)
        case 3:
            setRepeatOption(5)
        default:
            setRepeatOption(1)
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        savePlaybackState()
        updateNowPlayingInfo()
    }

    func scrub(to progress: Double) {
        guard duration > 0 else { return }
        seek(to: duration * min(max(progress, 0), 1))
    }

    func startSelectedLoop() {
        guard let segment = selectedSegment else { return }
        startSegmentPlayback(segment)
        isPlaying = true
    }

    private var normalizedBoundaryPoints: [Double] {
        guard duration > 0 else { return [] }
        var uniqueMarkers: [Double] = []
        for marker in markers {
            let clampedMarker = min(max(marker, 0), duration)
            guard uniqueMarkers.last.map({ abs($0 - clampedMarker) >= 0.1 }) ?? true else { continue }
            uniqueMarkers.append(clampedMarker)
        }
        return [0] + uniqueMarkers + [duration]
    }

    private func subtitleIndex(at time: Double) -> Int? {
        let subtitleTime = time - subtitleOffset
        var lowerBound = 0
        var upperBound = subtitles.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if subtitles[middle].start <= subtitleTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        var index = lowerBound - 1
        while index >= 0 {
            if subtitleTime < subtitles[index].end { return index }
            index -= 1
        }
        return nil
    }

    private func segmentIndex(at time: Double) -> Int? {
        var lowerBound = 0
        var upperBound = segments.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if segments[middle].start <= time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        let index = lowerBound - 1
        guard segments.indices.contains(index), time < segments[index].end else { return nil }
        return index
    }

    private func hasSubtitle(in segment: LoopSegment) -> Bool {
        if subtitleIndex(at: segment.start) != nil { return true }

        let subtitleStart = segment.start - subtitleOffset
        let subtitleEnd = segment.end - subtitleOffset
        var lowerBound = 0
        var upperBound = subtitles.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if subtitles[middle].start < subtitleStart {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return subtitles.indices.contains(lowerBound)
            && subtitles[lowerBound].start < subtitleEnd
    }

    private func followingSegment(after index: Int) -> LoopSegment? {
        guard index + 1 < segments.count else { return nil }
        return segments[index + 1]
    }

    private func seekToSubtitle(at index: Int) {
        guard subtitles.indices.contains(index) else { return }
        let targetSeconds = max(0, subtitles[index].start + subtitleOffset)
        let shouldResume = isPlaying

        playbackRevision += 1
        let revision = playbackRevision
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        completedRepeats = 0
        isTransitioningSegment = true
        currentTime = targetSeconds
        syncSelectedSegmentToCurrentTime()

        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished else { return }
                guard self.playbackRevision == revision else { return }
                self.currentTime = targetSeconds
                self.syncSelectedSegmentToCurrentTime()
                self.isTransitioningSegment = false
                self.savePlaybackState()
                if shouldResume {
                    self.player.playImmediately(atRate: 1)
                    self.isPlaying = true
                }
            }
        }
    }

    private func markerMatching(_ time: Double) -> Double? {
        markers.first { abs($0 - time) < 0.1 }
    }

    private func loadMatchingSubtitle(for videoURL: URL) {
        let baseURL = videoURL.deletingPathExtension()
        let candidates = ["srt", "SRT", "smi", "SMI", "vtt", "VTT"].map { baseURL.appendingPathExtension($0) }
        guard let matchingURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        loadSubtitle(from: matchingURL)
    }

    private func loadSubtitle(from url: URL) {
        hasAccessedSubtitleSecurityScopedResource = url.startAccessingSecurityScopedResource()
        let cues = SubtitleParser.parse(url: url)
        guard !cues.isEmpty else { return }
        subtitleURL = url
        subtitles = cues
    }

    private func rememberRecentVideo(_ videoURL: URL, subtitle explicitSubtitleURL: URL?) {
        do {
            let videoBookmark = try videoURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(videoBookmark, forKey: RecentFileKey.videoBookmark)

            if let explicitSubtitleURL {
                let subtitleBookmark = try explicitSubtitleURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(subtitleBookmark, forKey: RecentFileKey.subtitleBookmark)
            } else {
                UserDefaults.standard.removeObject(forKey: RecentFileKey.subtitleBookmark)
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: RecentFileKey.videoBookmark)
            UserDefaults.standard.removeObject(forKey: RecentFileKey.subtitleBookmark)
        }
    }

    private func loadRecentVideoIfAvailable() {
        guard let videoBookmark = UserDefaults.standard.data(forKey: RecentFileKey.videoBookmark),
              let videoURL = resolveBookmark(videoBookmark) else { return }

        let subtitleURL = UserDefaults.standard
            .data(forKey: RecentFileKey.subtitleBookmark)
            .flatMap(resolveBookmark)

        loadVideo(from: videoURL, subtitle: subtitleURL, remember: false)
    }

    private func playbackStateKey(for url: URL) -> String {
        let encodedPath = Data(url.path.utf8).base64EncodedString()
        return "playbackState.\(encodedPath)"
    }

    private func savePlaybackState() {
        guard let videoURL else { return }
        let state = PersistedPlaybackState(
            markers: markers,
            selectedSegmentIndex: selectedSegmentIndex,
            currentTime: currentTime,
            repeatCount: repeatCount,
            isInfiniteRepeat: isInfiniteRepeat,
            autoAdvanceAfterRepeat: autoAdvanceAfterRepeat,
            excludedSegmentStarts: Array(excludedSegmentStarts),
            isSubtitleVisible: isSubtitleVisible,
            subtitleOffset: subtitleOffset
        )

        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: playbackStateKey(for: videoURL))
    }

    private func saveRepeatSetting() {
        let defaults = UserDefaults.standard
        defaults.set(repeatCount, forKey: PlaybackSettingKey.repeatCount)
        defaults.set(lastFiniteRepeatCount, forKey: PlaybackSettingKey.finiteRepeatCount)
        defaults.set(isInfiniteRepeat, forKey: PlaybackSettingKey.isInfiniteRepeat)
        defaults.set(autoAdvanceAfterRepeat, forKey: PlaybackSettingKey.autoAdvanceAfterRepeat)
    }

    private func restoreRepeatSetting() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PlaybackSettingKey.repeatCount) != nil else { return }

        let savedCount = defaults.integer(forKey: PlaybackSettingKey.repeatCount)
        repeatCount = [0, 1, 3, 5].contains(savedCount) ? savedCount : 0
        let savedFiniteCount = defaults.integer(forKey: PlaybackSettingKey.finiteRepeatCount)
        if [1, 3, 5].contains(savedFiniteCount) {
            lastFiniteRepeatCount = savedFiniteCount
        } else if [1, 3, 5].contains(repeatCount) {
            lastFiniteRepeatCount = repeatCount
        }
        isInfiniteRepeat = defaults.bool(forKey: PlaybackSettingKey.isInfiniteRepeat)
        if defaults.object(forKey: PlaybackSettingKey.autoAdvanceAfterRepeat) != nil {
            autoAdvanceAfterRepeat = defaults.bool(forKey: PlaybackSettingKey.autoAdvanceAfterRepeat)
        }
    }

    private func restorePlaybackState(for url: URL) {
        guard let data = UserDefaults.standard.data(forKey: playbackStateKey(for: url)),
              let state = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data) else { return }

        markers = state.markers.sorted()
        excludedSegmentStarts = Set(state.excludedSegmentStarts ?? [])
        repeatCount = state.repeatCount
        if [1, 3, 5].contains(state.repeatCount) {
            lastFiniteRepeatCount = state.repeatCount
        }
        isInfiniteRepeat = state.isInfiniteRepeat
        autoAdvanceAfterRepeat = state.autoAdvanceAfterRepeat ?? true
        saveRepeatSetting()
        isSubtitleVisible = state.isSubtitleVisible
        subtitleOffset = state.subtitleOffset ?? 0
        currentTime = state.currentTime
        clampSelectedSegmentIndex(preferredIndex: state.selectedSegmentIndex)
        syncSelectedSegmentToCurrentTime(preferredIndex: state.selectedSegmentIndex)
        seek(to: state.currentTime)
    }

    private func resolveBookmark(_ bookmark: Data) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return isStale ? nil : url
        } catch {
            return nil
        }
    }

    private func observeDuration(for item: AVPlayerItem) {
        durationObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    let loadedDuration = try await item.asset.load(.duration)
                    let seconds = loadedDuration.seconds
                    if seconds.isFinite, seconds > 0 {
                        self.duration = seconds
                        self.updateNowPlayingInfo()
                    }
                } catch {
                    self.duration = 0
                }
            }
        }
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handleTimeUpdate(time.seconds)
            }
        }
    }

    private func handleTimeUpdate(_ seconds: Double) {
        guard seconds.isFinite else { return }
        guard !isTransitioningSegment else { return }
        currentTime = seconds

        let wholeSecond = Int(seconds)
        if wholeSecond != lastNowPlayingUpdateSecond {
            lastNowPlayingUpdateSecond = wholeSecond
            updateNowPlayingInfo()
        }

        guard isPlaying else { return }
        guard let segment = selectedSegment else { return }
        guard !(repeatCount == 0 && !isInfiniteRepeat) else { return }
        guard seconds >= segment.end else { return }

        let shouldRepeatSegment = hasSubtitle(in: segment)
            && isSegmentPlaybackSelected(segment)

        if shouldRepeatSegment && (isInfiniteRepeat || completedRepeats < targetPlaybackCount) {
            seekAndPlay(segment, revision: playbackRevision, startsNewPlayback: true)
        } else if autoAdvanceAfterRepeat,
                  let nextSegment = followingSegment(after: segment.index) {
            let revision = beginPlaybackTransition()
            selectedSegmentIndex = nextSegment.index
            currentTime = nextSegment.start
            savePlaybackState()
            seekAndPlay(nextSegment, revision: revision, startsNewPlayback: true)
        } else {
            player.pause()
            isPlaying = false
            completedRepeats = 0
            isTransitioningSegment = false
            seek(to: segment.start)
        }
    }

    private func startSegmentPlayback(_ segment: LoopSegment) {
        let revision = beginPlaybackTransition()
        selectedSegmentIndex = segment.index
        currentTime = segment.start
        savePlaybackState()
        seekAndPlay(segment, revision: revision, startsNewPlayback: true)
    }

    @discardableResult
    private func beginPlaybackTransition() -> Int {
        playbackRevision += 1
        player.pause()
        player.rate = 0
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        completedRepeats = 0
        isTransitioningSegment = true
        isPlaying = false
        return playbackRevision
    }

    private func seekAndPlay(_ segment: LoopSegment, revision: Int, startsNewPlayback: Bool) {
        isTransitioningSegment = true
        let target = CMTime(seconds: segment.start, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                guard finished else { return }
                guard self.playbackRevision == revision else { return }
                guard self.selectedSegmentIndex == segment.index else { return }

                self.currentTime = segment.start
                if startsNewPlayback, self.isInfiniteRepeat || self.repeatCount > 0 {
                    self.completedRepeats += 1
                }
                self.isTransitioningSegment = false
                self.savePlaybackState()
                self.player.playImmediately(atRate: 1.0)
                self.isPlaying = true
            }
        }
    }

    private func syncSelectedSegmentToCurrentTime(preferredIndex: Int? = nil) {
        guard !segments.isEmpty else {
            selectedSegmentIndex = 0
            return
        }

        if let preferredIndex, segments.indices.contains(preferredIndex) {
            let preferredSegment = segments[preferredIndex]
            if currentTime >= preferredSegment.start && currentTime < preferredSegment.end {
                selectedSegmentIndex = preferredIndex
                return
            }
        }

        if let matchingIndex = segmentIndex(at: currentTime) {
            selectedSegmentIndex = matchingIndex
            return
        }

        if let lastIndex = segments.indices.last, currentTime >= segments[lastIndex].start {
            selectedSegmentIndex = lastIndex
            return
        }

        clampSelectedSegmentIndex(preferredIndex: preferredIndex)
    }

    private func clampSelectedSegmentIndex(preferredIndex: Int? = nil) {
        if segments.isEmpty {
            selectedSegmentIndex = 0
        } else {
            let baseIndex = preferredIndex ?? selectedSegmentIndex
            selectedSegmentIndex = min(max(baseIndex, 0), segments.count - 1)
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        remoteCommandTargets.append(commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isPlaying, self.player.currentItem != nil else { return }
                self.player.play()
                self.isPlaying = true
            }
            return .success
        })

        remoteCommandTargets.append(commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.player.pause()
                self.isPlaying = false
            }
            return .success
        })

        remoteCommandTargets.append(commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayback()
            }
            return .success
        })

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        remoteCommandTargets.append(commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                self?.seek(to: event.positionTime)
            }
            return .success
        })
    }

    private func updateNowPlayingInfo() {
        guard let videoURL else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: videoURL.deletingPathExtension().lastPathComponent,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? player.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
