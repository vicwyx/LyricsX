//
//  AppController.swift
//
//  This file is part of LyricsX
//  Copyright (C) 2017 Xander Deng - https://github.com/ddddxxx/LyricsX
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import AppKit
import LyricsProvider
import MusicPlayer

class AppController: NSObject, MusicPlayerManagerDelegate, LyricsConsuming {
    
    static let shared = AppController()
    
    let lyricsManager = LyricsProviderManager()
    let playerManager = MusicPlayerManager()
    
    var currentLyrics: Lyrics? {
        willSet {
            willChangeValue(forKey: "lyricsOffset")
        }
        didSet {
            currentLyrics?.filtrate()
            didChangeValue(forKey: "lyricsOffset")
            NotificationCenter.default.post(name: .currentLyricsChange, object: nil)
            if currentLyrics?.metadata.source != .Local {
                currentLyrics?.saveToLocal()
            }
        }
    }
    
    var currentLineIndex: Int?
    
    var timer: Timer?
    
    @objc dynamic var lyricsOffset: Int {
        get {
            return currentLyrics?.offset ?? 0
        }
        set {
            currentLyrics?.offset = newValue
            currentLyrics?.saveToLocal()
        }
    }
    
    private override init() {
        super.init()
        playerManager.delegate = self
        lyricsManager.consumer = self
        playerManager.preferredPlayerName = MusicPlayerName(index: defaults[.PreferredPlayerIndex])
        
        timer = Timer(timeInterval: 0.1, target: self, selector: #selector(updatePlayerPosition), userInfo: nil, repeats: true)
        RunLoop.current.add(timer!, forMode: .commonModes)
        
        self.currentTrackChanged(track: playerManager.player?.currentTrack)
    }
    
    func writeToiTunes(overwrite: Bool) {
        guard let player = playerManager.player as? iTunes else {
            return
        }
        guard let currentLyrics = currentLyrics else {
            assertionFailure()
            return
        }
        if overwrite || player.currentLyrics == nil {
            let lyrics = currentLyrics.lines.map { line in
                var content = line.content
                if defaults[.WriteiTunesWithTranslation],
                    let translation = line.translation {
                    content += "\n" + translation
                }
                return content
            }.joined(separator: "\n")
            let regex = try! NSRegularExpression(pattern: "\\n{3}")
            let replaced = regex.stringByReplacingMatches(in: lyrics, range: NSRange(location: 0, length: lyrics.utf16.count), withTemplate: "\n\n")
            player.currentLyrics = replaced.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
    }
    
    // MARK: MusicPlayerManagerDelegate
    
    func runningStateChanged(isRunning: Bool) {
        if !isRunning, defaults[.LaunchAndQuitWithPlayer] {
            NSApplication.shared.terminate(nil)
        }
    }
    
    func currentPlayerChanged(player: MusicPlayer?) {
        currentTrackChanged(track: player?.currentTrack)
    }
    
    func playbackStateChanged(state: MusicPlaybackState) {
        NotificationCenter.default.post(name: .lyricsShouldDisplay, object: nil)
        if state == .playing {
            timer?.fireDate = Date()
        } else {
            timer?.fireDate = .distantFuture
        }
    }
    
    func currentTrackChanged(track: MusicTrack?) {
        currentLyrics = nil
        currentLineIndex = nil
        guard let track = track else {
            return
        }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        
        guard !defaults[.NoSearchingTrackIds].contains(track.id) else {
            return
        }
        
        // Load lyrics beside current track.
        if defaults[.LoadLyricsBesideTrack],
            let lrcURL = track.url?.deletingPathExtension().appendingPathExtension("lrc"),
            let lrcContents = try? String(contentsOf: lrcURL, encoding: String.Encoding.utf8),
            let lyrics = Lyrics(lrcContents) {
            lyrics.metadata.source = .Local
            lyrics.metadata.title = title
            lyrics.metadata.artist = artist
            currentLyrics = lyrics
            return
        }
        
        if let localLyrics = Lyrics.loadFromLocal(title: title, artist: artist) {
            currentLyrics = localLyrics
        } else {
            let duration = track.duration ?? 0
            lyricsManager.iFeelLucky(title: title, artist: artist, duration: duration)
        }
    }
    
    func playerPositionMutated(position: TimeInterval) {
        guard let lyrics = currentLyrics else {
            return
        }
        let index = lyrics[position + lyrics.timeDelay].currentLineIndex
        if currentLineIndex != index {
            currentLineIndex = index
            NotificationCenter.default.post(name: .lyricsShouldDisplay, object: nil)
        }
    }
    
    @objc func updatePlayerPosition() {
        guard let position = AppController.shared.playerManager.player?.playerPosition else {
            return
        }
        playerPositionMutated(position: position)
    }
    
    // MARK: LyricsSourceDelegate
    
    func lyricsReceived(lyrics: Lyrics) {
        #if IS_FOR_MAS
            guard defaults[.isInMASReview] == false else {
                return
            }
            checkForMASReview()
        #endif
        
        let track = AppController.shared.playerManager.player?.currentTrack
        guard lyrics.metadata.title == track?.title ?? "",
            lyrics.metadata.artist == track?.artist ?? "" else {
            return
        }
        
        func shoudReplace(_ from: Lyrics, to: Lyrics) -> Bool {
            if (from.metadata.source.rawValue == defaults[.PreferredLyricsSource]) != (to.metadata.source.rawValue == defaults[.PreferredLyricsSource]) {
                return to.metadata.source.rawValue == defaults[.PreferredLyricsSource]
            }
            return to > from
        }
        
        if let current = currentLyrics, !shoudReplace(current, to: lyrics) {
            return
        }
        
        currentLyrics = lyrics
    }
    
    func fetchCompleted(result: [Lyrics]) {
        if defaults[.WriteToiTunesAutomatically] {
            writeToiTunes(overwrite: true)
        }
    }
}

extension AppController {
    
    func importLyrics(_ lyricsString: String) {
        if let lrc = Lyrics(lyricsString),
            let track = AppController.shared.playerManager.player?.currentTrack {
            lrc.metadata.source = .Import
            lrc.metadata.title = track.title
            lrc.metadata.artist = track.artist
            currentLyrics = lrc
        }
    }
}
