import Foundation

public enum EQPreset: String, CaseIterable, Identifiable, Sendable {
    // Utility
    case flat
    case bassBoost
    case bassCut
    case trebleBoost
    // Speech
    case vocalClarity
    case podcast
    case spokenWord
    // Listening
    case loudness
    case lateNight
    case smallSpeakers
    // Music
    case rock
    case pop
    case electronic
    case jazz
    case classical
    case hipHop
    case rnb
    case deep
    case acoustic
    // Media
    case movie
    // Headphone
    case hpClarity
    case hpReference
    case hpVocalFocus

    public var id: String { rawValue }

    // MARK: - Categories

    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case utility = "Utility"
        case speech = "Speech"
        case listening = "Listening"
        case music = "Music"
        case media = "Media"
        case headphone = "Headphone"

        public var id: String { rawValue }
    }

    public var category: Category {
        switch self {
        case .flat, .bassBoost, .bassCut, .trebleBoost:
            return .utility
        case .vocalClarity, .podcast, .spokenWord:
            return .speech
        case .loudness, .lateNight, .smallSpeakers:
            return .listening
        case .rock, .pop, .electronic, .jazz, .classical, .hipHop, .rnb, .deep, .acoustic:
            return .music
        case .movie:
            return .media
        case .hpClarity, .hpReference, .hpVocalFocus:
            return .headphone
        }
    }

    public static func presets(for category: Category) -> [EQPreset] {
        allCases.filter { $0.category == category }
    }

    public var name: String {
        switch self {
        case .flat: return "Flat"
        case .bassBoost: return "Bass Boost"
        case .bassCut: return "Bass Cut"
        case .trebleBoost: return "Treble Boost"
        case .vocalClarity: return "Vocal Clarity"
        case .podcast: return "Podcast"
        case .spokenWord: return "Spoken Word"
        case .loudness: return "Loudness"
        case .lateNight: return "Late Night"
        case .smallSpeakers: return "Small Speakers"
        case .rock: return "Rock"
        case .pop: return "Pop"
        case .electronic: return "Electronic"
        case .jazz: return "Jazz"
        case .classical: return "Classical"
        case .hipHop: return "Hip-Hop"
        case .rnb: return "R&B"
        case .deep: return "Deep"
        case .acoustic: return "Acoustic"
        case .movie: return "Movie"
        case .hpClarity: return "HP: Clarity"
        case .hpReference: return "HP: Reference"
        case .hpVocalFocus: return "HP: Vocal Focus"
        }
    }

    // Bands: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k
    public var settings: EQSettings {
        switch self {
        // MARK: - Utility
        case .flat:
            return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        case .bassBoost:
            return EQSettings(bandGains: [10, 8, 5, 2, 0, 0, 0, 0, 0, 0])
        case .bassCut:
            return EQSettings(bandGains: [-8, -6, -4, -2, 0, 0, 0, 0, 0, 0])
        case .trebleBoost:
            return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 2, 5, 8, 10])

        // MARK: - Speech
        case .vocalClarity:
            return EQSettings(bandGains: [-4, -3, -1, -2, 0, 3, 5, 5, 2, 0])
        case .podcast:
            return EQSettings(bandGains: [-6, -4, -2, -1, 0, 3, 5, 4, 2, 0])
        case .spokenWord:
            return EQSettings(bandGains: [-8, -6, -3, -2, 0, 3, 5, 5, 2, 0])

        // MARK: - Listening
        case .loudness:
            return EQSettings(bandGains: [8, 6, 3, 0, -2, -2, 0, 3, 6, 8])
        case .lateNight:
            return EQSettings(bandGains: [-6, -4, -2, 0, 0, 1, 2, 2, 1, 0])
        case .smallSpeakers:
            return EQSettings(bandGains: [4, 5, 6, 3, 0, 1, 3, 3, 2, 0])

        // MARK: - Music
        case .rock:
            return EQSettings(bandGains: [6, 4, 0, -2, -1, 2, 4, 6, 4, 3])
        case .pop:
            return EQSettings(bandGains: [4, 4, 2, 0, -1, 2, 3, 4, 4, 5])
        case .electronic:
            return EQSettings(bandGains: [10, 8, 4, 0, -3, -3, 2, 6, 8, 6])
        case .jazz:
            return EQSettings(bandGains: [4, 3, 1, 0, 0, 0, 1, 3, 3, 2])
        case .classical:
            return EQSettings(bandGains: [0, 0, 0, 0, 0, 0, 1, 3, 3, 3])
        case .hipHop:
            return EQSettings(bandGains: [10, 9, 5, 2, 0, -1, 1, 3, 5, 4])
        case .rnb:
            return EQSettings(bandGains: [6, 5, 4, 1, -1, 0, 3, 4, 4, 3])
        case .deep:
            return EQSettings(bandGains: [8, 8, 5, 1, -3, -3, 0, 2, 3, 2])
        case .acoustic:
            return EQSettings(bandGains: [0, 1, 3, 3, 1, 0, 2, 3, 3, 2])

        // MARK: - Media
        case .movie:
            return EQSettings(bandGains: [6, 5, 4, -1, -1, 2, 4, 4, 3, 2])

        // MARK: - Headphone
        case .hpClarity:
            return EQSettings(bandGains: [-3, -3, -4, -3, -2, 0, 2, 2, 1, 1])
        case .hpReference:
            return EQSettings(bandGains: [-5, -5, -6, -4, -1, 0, 0, 1, -1, -2])
        case .hpVocalFocus:
            return EQSettings(bandGains: [-7, -6, -5, -3, -2, 2, 4, 4, 1, -1])
        }
    }
}
