enum SpeakerProfileMergeSideEffectCoordinator {
    static func merge(
        databaseMerge: () throws -> Void,
        promoteClip: () -> Void,
        deleteSourceClips: () -> Void
    ) rethrows {
        try databaseMerge()
        promoteClip()
        deleteSourceClips()
    }
}
