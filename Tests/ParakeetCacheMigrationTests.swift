import Foundation

func testParakeetCacheMigration() {
    runSuite("Legacy Parakeet caches migrate without overwrites or symlink traversal") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ParakeetMigration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)

        for variant in ParakeetModelVariant.allCases {
            let cache = root.appendingPathComponent(variant.rawValue)
            let legacy = cache.appendingPathComponent(variant.directoryName + "-coreml")
            let current = cache.appendingPathComponent(variant.directoryName)
            assertFalse(try! ModelCacheInventory.migrateLegacyParakeetModelDirectory(
                variant: variant, fluidAudioModelsDirectory: cache
            ), "an absent legacy cache is a no-op")
            try! fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            let bytes = Data([1, 2, 3, 4])
            try! bytes.write(to: legacy.appendingPathComponent("existing-model.bin"))
            assertTrue(try! ModelCacheInventory.migrateLegacyParakeetModelDirectory(
                variant: variant, fluidAudioModelsDirectory: cache
            ))
            assertEqual(try! Data(contentsOf: current.appendingPathComponent("existing-model.bin")), bytes)
            assertFalse(fm.fileExists(atPath: legacy.path))
            assertFalse(try! ModelCacheInventory.migrateLegacyParakeetModelDirectory(
                variant: variant, fluidAudioModelsDirectory: cache
            ), "repeated migration is a no-op")

            try! fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try! Data([9]).write(to: legacy.appendingPathComponent("legacy-only.bin"))
            assertFalse(try! ModelCacheInventory.migrateLegacyParakeetModelDirectory(
                variant: variant, fluidAudioModelsDirectory: cache
            ), "coexisting canonical cache must not be merged or overwritten")
            assertEqual(try! Data(contentsOf: current.appendingPathComponent("existing-model.bin")), bytes)
            assertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("legacy-only.bin").path))
        }

        for collision in ["source-link", "destination-link", "root-link"] {
            let cache = root.appendingPathComponent(collision)
            let target = root.appendingPathComponent(collision + "-target")
            try! fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try! fm.createDirectory(at: target, withIntermediateDirectories: true)
            let legacy = cache.appendingPathComponent(ParakeetModelVariant.v2.directoryName + "-coreml")
            let current = cache.appendingPathComponent(ParakeetModelVariant.v2.directoryName)
            var suppliedCache = cache
            if collision == "source-link" {
                try! fm.createSymbolicLink(at: legacy, withDestinationURL: target)
            } else {
                try! fm.createDirectory(at: legacy, withIntermediateDirectories: true)
                if collision == "destination-link" {
                    // A dangling link is still a collision despite fileExists == false.
                    try! fm.createSymbolicLink(at: current, withDestinationURL: target.appendingPathComponent("absent"))
                } else {
                    suppliedCache = root.appendingPathComponent("linked-cache")
                    try! fm.createSymbolicLink(at: suppliedCache, withDestinationURL: cache)
                }
            }
            assertFalse(try! ModelCacheInventory.migrateLegacyParakeetModelDirectory(
                variant: .v2, fluidAudioModelsDirectory: suppliedCache
            ), "\(collision) must remain untouched")
            assertTrue(fm.fileExists(atPath: legacy.path))
            assertTrue(fm.fileExists(atPath: target.path))
        }
    }
}
