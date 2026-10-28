import BiliModels

// Extracted from upstream PlayerTypes.swift so the bridge can build independently.
public struct SelectedPlaybackAudioTrack: Sendable, Equatable {
    public let track: PlaybackAudioTrack
    public let representation: MediaRepresentation
    public init(track: PlaybackAudioTrack, representation: MediaRepresentation) {
        self.track = track
        self.representation = representation
    }
}

// Extracted from upstream LoudnessAudioTrackMatching.swift; playlist metadata only.
extension PlaybackAudioTrack.Role {
    var hlsCharacteristic: String {
        switch self {
        case .original: "public.original-content"
        case .machineGenerated: "public.machine-generated"
        }
    }
}
