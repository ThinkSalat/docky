//
//  MediaPlaybackService.swift
//  Docky
//

import AppKit
import Combine
import Foundation
import OSLog

struct SyncedLyricsLine: Equatable {
    let time: TimeInterval
    let text: String
}

struct LyricsContent: Equatable {
    let plain: String
    let lines: [SyncedLyricsLine]

    var hasSyncedLines: Bool { !lines.isEmpty }
}

enum LyricsLoadState: Equatable {
    case loading
    case loaded(LyricsContent)
    case unavailable
}

struct MediaPlaybackState: Equatable {
    let bundleIdentifier: String
    var displayName: String
    var title: String
    var artist: String
    var album: String
    var currentTime: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    var isAvailable: Bool
    var supportsFavorite: Bool
    var isFavorite: Bool
    var artworkData: Data?
    var artworkRevision: String?
    var lastUpdated: Date
    var isPresentable: Bool {
        isAvailable && hasContent
    }

    var hasContent: Bool {
        !title.isEmpty || !artist.isEmpty || artworkData != nil
    }

    var estimatedCurrentTime: TimeInterval {
        guard isPlaying, duration > 0 else {
            return min(max(currentTime, 0), duration)
        }

        let elapsed = Date().timeIntervalSince(lastUpdated)
        return min(max(currentTime + elapsed, 0), duration)
    }
}

struct MediaAppChoice: Equatable, Identifiable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

private struct MediaFavoriteMutation: Sendable {
    let id: UUID
    let trackKey: String
    let priorFavorite: Bool?
}

final class MediaPlaybackService: ObservableObject {
    static let shared = MediaPlaybackService()
    static let genericNowPlayingOwnerBundleIdentifier = WidgetOwnerBundleIdentifiers.genericNowPlaying

    @Published private(set) var statesByBundleIdentifier: [String: MediaPlaybackState] = [:]
    @Published private(set) var lyricsByTrackKey: [String: LyricsLoadState] = [:]

    private let mediaRemote = MediaRemoteBridge.shared
    private var resolvedDisplayNameByBundleIdentifier: [String: String] = [:]
    private var displayNameResolutionTaskByBundleIdentifier:
        [String: Task<Void, Never>] = [:]

    private init() {
        mediaRemote.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.apply(state)
            }
        }

        // Avoid re-entrant work while `shared` is still being initialized.
        DispatchQueue.main.async { [weak self] in
            self?.activate()
        }
    }

    private func activate() {
        mediaRemote.start()
    }

    func supportsWidget(bundleIdentifier: String) -> Bool {
        if bundleIdentifier == Self.genericNowPlayingOwnerBundleIdentifier {
            return true
        }

        return !bundleIdentifier.isEmpty
    }

    func state(for bundleIdentifier: String) -> MediaPlaybackState? {
        if bundleIdentifier == Self.genericNowPlayingOwnerBundleIdentifier {
            return currentState
        }

        return statesByBundleIdentifier[bundleIdentifier]
    }

    var currentState: MediaPlaybackState? {
        statesByBundleIdentifier.values
            .filter(\ .hasContent)
            .max { lhs, rhs in lhs.lastUpdated < rhs.lastUpdated }
    }

    /// Trackable media apps for the per-widget picker, derived from what MediaRemote reports; the generic placeholder is excluded (offered separately as "Automatic").
    func availableMediaApps() -> [MediaAppChoice] {
        statesByBundleIdentifier.values
            .filter { $0.bundleIdentifier != Self.genericNowPlayingOwnerBundleIdentifier }
            .map { MediaAppChoice(bundleIdentifier: $0.bundleIdentifier, displayName: $0.displayName) }
            .sorted { lhs, rhs in
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if comparison == .orderedSame {
                    return lhs.bundleIdentifier.localizedCaseInsensitiveCompare(rhs.bundleIdentifier) == .orderedAscending
                }
                return comparison == .orderedAscending
            }
    }

    func refresh() {
        mediaRemote.start()
    }

    func togglePlayPause(for bundleIdentifier: String) async {
        guard let resolvedBundleIdentifier = resolvedBundleIdentifier(for: bundleIdentifier),
              let currentState = state(for: resolvedBundleIdentifier),
              currentState.hasContent else {
            return
        }

        var updatedState = currentState
        updatedState.isPlaying.toggle()
        updatedState.lastUpdated = Date()
        statesByBundleIdentifier[resolvedBundleIdentifier] = updatedState

        mediaRemote.sendCommand(.togglePlayPause)
        try? await Task.sleep(for: .milliseconds(120))
        refresh()
    }

    func pressPlayPauseButton(for bundleIdentifier: String) async {
        if state(for: bundleIdentifier)?.isPlaying == true {
            await togglePlayPause(for: bundleIdentifier)
            return
        }

        mediaRemote.sendCommand(.play)
        try? await Task.sleep(for: .milliseconds(120))
        refresh()
    }

    func skipToNext(for bundleIdentifier: String) async {
        guard let resolvedBundleIdentifier = resolvedBundleIdentifier(for: bundleIdentifier),
              state(for: resolvedBundleIdentifier)?.hasContent == true else {
            return
        }

        mediaRemote.sendCommand(.nextTrack)
        try? await Task.sleep(for: .milliseconds(120))
        refresh()
    }

    func skipToPrevious(for bundleIdentifier: String) async {
        guard let resolvedBundleIdentifier = resolvedBundleIdentifier(for: bundleIdentifier),
              state(for: resolvedBundleIdentifier)?.hasContent == true else {
            return
        }

        mediaRemote.sendCommand(.previousTrack)
        try? await Task.sleep(for: .milliseconds(120))
        refresh()
    }

    func supportsLyrics(for bundleIdentifier: String) -> Bool {
        guard let resolved = resolvedBundleIdentifier(for: bundleIdentifier),
              let state = state(for: resolved),
              !state.title.isEmpty,
              !state.artist.isEmpty else {
            return false
        }
        return true
    }

    func currentTrackKey(for bundleIdentifier: String) -> String? {
        guard let resolved = resolvedBundleIdentifier(for: bundleIdentifier),
              let state = state(for: resolved),
              state.hasContent else {
            return nil
        }

        return "\(resolved)|\(state.title)|\(state.artist)|\(state.album)"
    }

    func lyricsState(for bundleIdentifier: String) -> LyricsLoadState? {
        guard let key = currentTrackKey(for: bundleIdentifier) else { return nil }
        return lyricsByTrackKey[key]
    }

    func requestLyrics(for bundleIdentifier: String) {
        guard let resolved = resolvedBundleIdentifier(for: bundleIdentifier),
              let state = state(for: resolved),
              !state.title.isEmpty,
              !state.artist.isEmpty,
              let key = currentTrackKey(for: bundleIdentifier),
              lyricsByTrackKey[key] == nil else {
            return
        }

        lyricsByTrackKey[key] = .loading

        let title = state.title
        let artist = state.artist
        let album = state.album
        let duration = Int(state.duration.rounded())

        Task { @MainActor in
            let content = await Self.fetchLyricsFromLRClib(
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
            self.lyricsByTrackKey[key] = content.map { .loaded($0) } ?? .unavailable
        }
    }

    private nonisolated struct LRCEntry: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    nonisolated private static func fetchLyricsFromLRClib(
        title: String,
        artist: String,
        album: String,
        duration: Int
    ) async -> LyricsContent? {
        if let content = await fetchLRClibGet(title: title, artist: artist, album: album, duration: duration) {
            return content
        }
        return await fetchLRClibSearch(title: title, artist: artist)
    }

    nonisolated private static func fetchLRClibGet(
        title: String,
        artist: String,
        album: String,
        duration: Int
    ) async -> LyricsContent? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components?.queryItems = items

        guard let entry: LRCEntry = await fetchDecodable(from: components?.url) else {
            return nil
        }
        return resolvedLyrics(from: entry)
    }

    nonisolated private static func fetchLRClibSearch(
        title: String,
        artist: String
    ) async -> LyricsContent? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]

        guard let entries: [LRCEntry] = await fetchDecodable(from: components?.url) else {
            return nil
        }
        for entry in entries {
            if let content = resolvedLyrics(from: entry) {
                return content
            }
        }
        return nil
    }

    nonisolated private static func fetchDecodable<T: Decodable>(from url: URL?) async -> T? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Docky/1.0 (lyrics fetcher)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func resolvedLyrics(from entry: LRCEntry) -> LyricsContent? {
        if entry.instrumental == true {
            return LyricsContent(plain: "♪ Instrumental ♪", lines: [])
        }
        let synced = entry.syncedLyrics.map(parseLRC) ?? []
        let plain: String = {
            let plainCandidate = entry.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !plainCandidate.isEmpty {
                return plainCandidate
            }
            return synced.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        guard !plain.isEmpty || !synced.isEmpty else {
            return nil
        }
        return LyricsContent(plain: plain, lines: synced)
    }

    nonisolated private static func parseLRC(_ raw: String) -> [SyncedLyricsLine] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#
        ) else {
            return []
        }

        var result: [SyncedLyricsLine] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let nsLine = line as NSString
            let matches = pattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }

            let textStart = matches.map(\.range.upperBound).max() ?? 0
            let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)

            for match in matches {
                let mmRange = match.range(at: 1)
                let ssRange = match.range(at: 2)
                let xxRange = match.range(at: 3)
                guard let mm = Int(nsLine.substring(with: mmRange)),
                      let ss = Int(nsLine.substring(with: ssRange)) else {
                    continue
                }

                let fractional: TimeInterval
                if xxRange.location != NSNotFound {
                    fractional = Double("0.\(nsLine.substring(with: xxRange))") ?? 0
                } else {
                    fractional = 0
                }

                result.append(SyncedLyricsLine(time: TimeInterval(mm * 60 + ss) + fractional, text: text))
            }
        }

        return result.sorted { $0.time < $1.time }
    }

    func setFavorite(_ favorite: Bool, for bundleIdentifier: String) async {
        guard let resolvedBundleIdentifier = resolvedBundleIdentifier(for: bundleIdentifier),
              resolvedBundleIdentifier == "com.apple.Music",
              let mutation = mediaRemote.beginFavoriteMutation(
                for: resolvedBundleIdentifier
              ) else {
            return
        }

        let source = """
        tell application "Music"
            if it is not running then
                error "Music is not running."
            end if
            set favorited of current track to \(favorite ? "true" : "false")
            return favorited of current track
        end tell
        """

        let verifiedFavorite: Bool
        do {
            verifiedFavorite = try await AppleScriptService.shared
                .executeBoolean(source: source)
        } catch {
            mediaRemote.abandonFavoriteMutation(mutation)
            return
        }
        guard verifiedFavorite == favorite else {
            mediaRemote.abandonFavoriteMutation(mutation)
            return
        }
        guard mediaRemote.recordFavorite(
                verifiedFavorite,
                for: resolvedBundleIdentifier,
                mutation: mutation
              ) else {
            mediaRemote.abandonFavoriteMutation(mutation)
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        refresh()
    }

    func resolvedBundleIdentifier(for bundleIdentifier: String) -> String? {
        if bundleIdentifier == Self.genericNowPlayingOwnerBundleIdentifier {
            return currentState?.bundleIdentifier
        }

        return bundleIdentifier.isEmpty ? nil : bundleIdentifier
    }

    private func apply(_ state: MediaPlaybackState?) {
        guard let state else {
            let now = Date()
            statesByBundleIdentifier = statesByBundleIdentifier.mapValues { existingState in
                var updatedState = existingState
                updatedState.title = ""
                updatedState.artist = ""
                updatedState.album = ""
                updatedState.currentTime = 0
                updatedState.duration = 0
                updatedState.isAvailable = false
                updatedState.isPlaying = false
                updatedState.artworkData = nil
                updatedState.artworkRevision = nil
                updatedState.lastUpdated = now
                return updatedState
            }
            return
        }

        var updatedState = state
        if let displayName =
            resolvedDisplayNameByBundleIdentifier[
                state.bundleIdentifier
            ] {
            updatedState.displayName = displayName
        } else {
            updatedState.displayName = String(localized: "Now Playing")
            resolveDisplayNameIfNeeded(
                bundleIdentifier: state.bundleIdentifier
            )
        }
        statesByBundleIdentifier[state.bundleIdentifier] = updatedState
    }

    private func resolveDisplayNameIfNeeded(
        bundleIdentifier: String
    ) {
        guard !bundleIdentifier.isEmpty,
              resolvedDisplayNameByBundleIdentifier[
                bundleIdentifier
              ] == nil,
              displayNameResolutionTaskByBundleIdentifier[
                bundleIdentifier
              ] == nil else {
            return
        }

        displayNameResolutionTaskByBundleIdentifier[bundleIdentifier] =
            Task { @MainActor [weak self] in
                let applicationURL =
                    await ApplicationURLResolver.shared.applicationURL(
                        for: bundleIdentifier
                    )
                guard let self else { return }
                self.displayNameResolutionTaskByBundleIdentifier[
                    bundleIdentifier
                ] = nil

                guard !Task.isCancelled,
                      let displayName = applicationURL?
                        .deletingPathExtension()
                        .lastPathComponent
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ),
                      !displayName.isEmpty else {
                    return
                }

                self.resolvedDisplayNameByBundleIdentifier[
                    bundleIdentifier
                ] = displayName
                guard var currentState =
                    self.statesByBundleIdentifier[
                        bundleIdentifier
                    ] else {
                    return
                }
                currentState.displayName = displayName
                self.statesByBundleIdentifier[
                    bundleIdentifier
                ] = currentState
            }
    }
}

private struct MediaRemoteSnapshot: Decodable {
    let type: String?
    let diff: Bool?
    let payload: Payload

    struct Payload: Decodable {
        let bundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTime: Double?
        let playing: Bool?
        let artworkData: String?
        let artworkMimeType: String?
        let timestamp: String?

        func merged(over base: Self?) -> Self {
            Self(
                bundleIdentifier: bundleIdentifier ?? base?.bundleIdentifier,
                parentApplicationBundleIdentifier: parentApplicationBundleIdentifier ?? base?.parentApplicationBundleIdentifier,
                title: title ?? base?.title,
                artist: artist ?? base?.artist,
                album: album ?? base?.album,
                duration: duration ?? base?.duration,
                elapsedTime: elapsedTime ?? base?.elapsedTime,
                playing: playing ?? base?.playing,
                artworkData: artworkData ?? base?.artworkData,
                artworkMimeType: artworkMimeType ?? base?.artworkMimeType,
                timestamp: timestamp ?? base?.timestamp
            )
        }
    }
}

/// Produces a stable revision while artwork bytes are unchanged and a new
/// revision whenever the bytes change. Metadata and byte count are not content
/// identities: two covers can share both and must still restart SwiftUI's
/// artwork preparation task.
private struct MediaArtworkRevisionTracker {
    private struct Entry {
        let data: Data
        let revision: UInt64
    }

    private var entryByBundleIdentifier: [String: Entry] = [:]
    private var nextRevision: UInt64 = 0

    mutating func revision(
        for data: Data?,
        bundleIdentifier: String
    ) -> String? {
        guard let data else {
            entryByBundleIdentifier.removeValue(
                forKey: bundleIdentifier
            )
            return nil
        }
        if let previous =
            entryByBundleIdentifier[bundleIdentifier],
           previous.data == data {
            return String(previous.revision)
        }

        nextRevision &+= 1
        let revision = nextRevision
        entryByBundleIdentifier[bundleIdentifier] = Entry(
            data: data,
            revision: revision
        )
        return String(revision)
    }
}

private final class MediaRemoteBridge {
    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    typealias SendCommand = @convention(c) (Int32, AnyObject?) -> Bool

    static let shared = MediaRemoteBridge()

    var onStateChange: ((MediaPlaybackState?) -> Void)?

    private let sendRemoteCommand: SendCommand?
    private let helper = MediaRemoteHelperProcess()
    private var lastPayloadByBundleIdentifier: [String: MediaRemoteSnapshot.Payload] = [:]
    private var lastActiveBundleIdentifier: String?
    private var latestStateByBundleIdentifier:
        [String: MediaPlaybackState] = [:]
    private var artworkRevisionTracker =
        MediaArtworkRevisionTracker()
    private var favoriteByTrackKey: [String: Bool] = [:]
    private var favoriteLookupID: UUID?
    private var favoriteLookupTrackKey: String?
    private var favoriteLookupTask: Task<Void, Never>?
    private var favoriteMutation: MediaFavoriteMutation?

    private init() {
        let bundleURL = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL)
        self.sendRemoteCommand = Self.function(named: "MRMediaRemoteSendCommand", in: bundle)

        helper.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.handle(snapshot)
            }
        }
    }

    func start() {
        helper.startIfNeeded()
    }

    func refresh() {
        helper.startIfNeeded()
    }

    func sendCommand(_ command: Command) {
        _ = sendRemoteCommand?(command.rawValue, nil)
    }

    private func handle(_ snapshot: MediaRemoteSnapshot?) {
        guard let snapshot else {
            cancelFavoriteLookup()
            favoriteMutation = nil
            onStateChange?(nil)
            return
        }

        let candidateBundleIdentifier = snapshot.payload.parentApplicationBundleIdentifier ?? snapshot.payload.bundleIdentifier
        let basePayload = candidateBundleIdentifier.flatMap { lastPayloadByBundleIdentifier[$0] }
            ?? lastActiveBundleIdentifier.flatMap { lastPayloadByBundleIdentifier[$0] }
        let payload = snapshot.diff == true ? snapshot.payload.merged(over: basePayload) : snapshot.payload
        let bundleIdentifier = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier ?? ""
        let title = payload.title ?? ""
        let artist = payload.artist ?? ""
        let album = payload.album ?? ""
        let duration = payload.duration ?? 0
        let elapsedTime = payload.elapsedTime ?? 0
        let isPlaying = payload.playing ?? false
        let artworkData = payload.artworkData.flatMap { Data(base64Encoded: $0) }

        guard !bundleIdentifier.isEmpty,
              !title.isEmpty || !artist.isEmpty || artworkData != nil else {
            cancelFavoriteLookup()
            favoriteMutation = nil
            onStateChange?(nil)
            return
        }
        let artworkRevision = artworkRevisionTracker.revision(
            for: artworkData,
            bundleIdentifier: bundleIdentifier
        )

        lastPayloadByBundleIdentifier[bundleIdentifier] = payload
        lastActiveBundleIdentifier = bundleIdentifier

        let trackKey = favoriteTrackKey(
            bundleIdentifier: bundleIdentifier,
            title: title,
            artist: artist,
            album: album
        )
        if bundleIdentifier != "com.apple.Music"
            || favoriteLookupTrackKey != trackKey
            || favoriteByTrackKey[trackKey] != nil {
            cancelFavoriteLookup()
        }
        if favoriteMutation?.trackKey != trackKey {
            favoriteMutation = nil
        }
        let state = MediaPlaybackState(
            bundleIdentifier: bundleIdentifier,
            displayName: "",
            title: title,
            artist: artist,
            album: album,
            currentTime: elapsedTime,
            duration: duration,
            isPlaying: isPlaying,
            isAvailable: true,
            supportsFavorite: bundleIdentifier == "com.apple.Music",
            isFavorite: favoriteByTrackKey[trackKey]
                ?? (
                    favoriteMutation?.trackKey == trackKey
                        ? favoriteMutation?.priorFavorite
                        : nil
                )
                ?? false,
            artworkData: artworkData,
            artworkRevision: artworkRevision,
            lastUpdated: Date()
        )
        latestStateByBundleIdentifier[bundleIdentifier] = state
        onStateChange?(state)

        if bundleIdentifier == "com.apple.Music",
           favoriteByTrackKey[trackKey] == nil,
           favoriteMutation?.trackKey != trackKey,
           favoriteLookupTrackKey != trackKey {
            scheduleFavoriteLookup(
                bundleIdentifier: bundleIdentifier,
                trackKey: trackKey
            )
        }
    }

    func recordFavorite(
        _ favorite: Bool,
        for bundleIdentifier: String,
        mutation: MediaFavoriteMutation
    ) -> Bool {
        guard bundleIdentifier == "com.apple.Music",
              favoriteMutation?.id == mutation.id,
              var latestState =
                latestStateByBundleIdentifier[bundleIdentifier],
              favoriteTrackKey(for: latestState)
                == mutation.trackKey else {
            return false
        }

        cancelFavoriteLookup()
        favoriteMutation = nil
        favoriteByTrackKey[mutation.trackKey] = favorite
        latestState.isFavorite = favorite
        latestState.lastUpdated = Date()
        latestStateByBundleIdentifier[bundleIdentifier] = latestState
        onStateChange?(latestState)
        return true
    }

    func beginFavoriteMutation(
        for bundleIdentifier: String
    ) -> MediaFavoriteMutation? {
        guard bundleIdentifier == "com.apple.Music",
              let latestState =
                latestStateByBundleIdentifier[bundleIdentifier] else {
            return nil
        }
        cancelFavoriteLookup()
        let trackKey = favoriteTrackKey(for: latestState)
        let priorFavorite = favoriteByTrackKey.removeValue(
            forKey: trackKey
        ) ?? (
            favoriteMutation?.trackKey == trackKey
                ? favoriteMutation?.priorFavorite
                : nil
        )
        let mutation = MediaFavoriteMutation(
            id: UUID(),
            trackKey: trackKey,
            priorFavorite: priorFavorite
        )
        favoriteMutation = mutation
        return mutation
    }

    func abandonFavoriteMutation(
        _ mutation: MediaFavoriteMutation
    ) {
        guard favoriteMutation?.id == mutation.id else { return }
        favoriteMutation = nil

        guard favoriteByTrackKey[mutation.trackKey] == nil,
              let latestState =
                latestStateByBundleIdentifier["com.apple.Music"],
              favoriteTrackKey(for: latestState)
                == mutation.trackKey else {
            return
        }
        scheduleFavoriteLookup(
            bundleIdentifier: "com.apple.Music",
            trackKey: mutation.trackKey
        )
    }

    private func scheduleFavoriteLookup(
        bundleIdentifier: String,
        trackKey: String
    ) {
        cancelFavoriteLookup()
        let lookupID = UUID()
        favoriteLookupID = lookupID
        favoriteLookupTrackKey = trackKey
        favoriteLookupTask = Task { @MainActor [weak self] in
            let favorite = await Self.fetchFavorite(
                bundleIdentifier: bundleIdentifier
            )
            guard let self else { return }
            guard favoriteLookupID == lookupID else { return }

            favoriteLookupID = nil
            favoriteLookupTrackKey = nil
            favoriteLookupTask = nil
            guard !Task.isCancelled,
                  let favorite,
                  favoriteByTrackKey[trackKey] == nil,
                  var latestState =
                    latestStateByBundleIdentifier[bundleIdentifier],
                  favoriteTrackKey(for: latestState) == trackKey else {
                return
            }

            favoriteByTrackKey[trackKey] = favorite
            latestState.isFavorite = favorite
            latestStateByBundleIdentifier[bundleIdentifier] = latestState
            onStateChange?(latestState)
        }
    }

    private func cancelFavoriteLookup() {
        favoriteLookupID = nil
        favoriteLookupTrackKey = nil
        let task = favoriteLookupTask
        favoriteLookupTask = nil
        task?.cancel()
    }

    private static func fetchFavorite(
        bundleIdentifier: String
    ) async -> Bool? {
        guard bundleIdentifier == "com.apple.Music" else {
            return nil
        }
        let source = """
        tell application "Music"
            if it is not running then
                error "Music is not running."
            end if
            return favorited of current track
        end tell
        """

        return try? await AppleScriptService.shared.executeBoolean(
            source: source
        )
    }

    private func favoriteTrackKey(
        for state: MediaPlaybackState
    ) -> String {
        favoriteTrackKey(
            bundleIdentifier: state.bundleIdentifier,
            title: state.title,
            artist: state.artist,
            album: state.album
        )
    }

    private func favoriteTrackKey(
        bundleIdentifier: String,
        title: String,
        artist: String,
        album: String
    ) -> String {
        "\(bundleIdentifier)|\(title)|\(artist)|\(album)"
    }

    private static func function<T>(named name: String, in bundle: CFBundle?) -> T? {
        guard let bundle,
              let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
            return nil
        }

        return unsafeBitCast(pointer, to: T.self)
    }
}

private final class MediaRemoteHelperProcess {
    private static let logger = Logger(subsystem: "gt.quintero.Docky", category: "MediaRemoteHelper")

    var onSnapshot: ((MediaRemoteSnapshot?) -> Void)?

    private var process: Process?
    private var outputPipe: Pipe?
    private var bufferedOutput = Data()

    func startIfNeeded() {
        guard process?.isRunning != true else {
            Self.logger.debug("startIfNeeded skipped; helper already running")
            return
        }

        Self.logger.debug("startIfNeeded beginning helper launch")
        stop()

        guard let launch = resolveLaunchConfiguration() else {
            Self.logger.error("Failed to resolve helper launch configuration")
            return
        }

        Self.logger.debug("Launching helper executable: \(launch.executablePath, privacy: .public)")

        let process = Process()
        let outputPipe = Pipe()
        self.outputPipe = outputPipe
        process.executableURL = URL(fileURLWithPath: launch.executablePath)
        process.arguments = launch.arguments
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            Self.logger.debug("Helper terminated")
            DispatchQueue.main.async {
                self?.handleTermination()
            }
        }

        installOutputReader()

        do {
            try process.run()
            self.process = process
            Self.logger.debug("Helper process launched successfully")
        } catch {
            Self.logger.error("Helper process failed to launch: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    private func stop() {
        Self.logger.debug("Stopping helper process")
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        bufferedOutput.removeAll(keepingCapacity: false)
        outputPipe = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
    }

    private func installOutputReader() {
        guard let outputPipe else {
            Self.logger.error("installOutputReader called without output pipe")
            return
        }

        Self.logger.debug("Installing output reader")
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.drainOutput(from: handle)
        }
    }

    private func drainOutput(from handle: FileHandle) {
        let data = handle.availableData
        guard !data.isEmpty else {
            return
        }

        Self.logger.debug("drainOutput received \(data.count) bytes")

        bufferedOutput.append(data)

        while let newline = bufferedOutput.firstIndex(of: 0x0A) {
            let lineData = bufferedOutput.prefix(upTo: newline)
            bufferedOutput.removeSubrange(...newline)

            guard !lineData.isEmpty else {
                continue
            }

            if let text = String(data: lineData, encoding: .utf8) {
                Self.logger.debug("Helper raw line: \(text, privacy: .public)")
            }

            if let snapshot = try? JSONDecoder().decode(MediaRemoteSnapshot.self, from: lineData) {
                let bundleIdentifier = snapshot.payload.parentApplicationBundleIdentifier ?? snapshot.payload.bundleIdentifier ?? ""
                Self.logger.debug("Decoded helper snapshot for \(bundleIdentifier, privacy: .public)")
                onSnapshot?(snapshot)
            } else if let text = String(data: lineData, encoding: .utf8), text == "null" {
                Self.logger.debug("Decoded helper null snapshot")
                onSnapshot?(nil)
            } else if let text = String(data: lineData, encoding: .utf8) {
                Self.logger.error("Failed to decode helper line: \(text, privacy: .public)")
            }
        }
    }

    private func handleTermination() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil
    }

    private func resolveLaunchConfiguration() -> HelperLaunchConfiguration? {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework") else {
            return nil
        }

        Self.logger.debug("Using bundled MediaRemote adapter")
        return HelperLaunchConfiguration(
            executablePath: "/usr/bin/perl",
            arguments: [scriptURL.path, frameworkPath, "stream"]
        )
    }
}

private struct HelperLaunchConfiguration {
    let executablePath: String
    let arguments: [String]
}
