import Foundation

func testMeetingLanguageDetectionPolicy() {
    runSuite("Acoustic detection uses log probabilities, rejecting invalid or weak evidence") {
        let supported: Set<String> = ["en", "fi"]
        assertEqual(MeetingLanguageDetectionPolicy.confidentLanguage(code: "fi", logProbability: log(0.95), supportedCodes: supported), "fi")
        assertNil(MeetingLanguageDetectionPolicy.confidentLanguage(code: "fi", logProbability: log(0.60), supportedCodes: supported))
        assertNil(MeetingLanguageDetectionPolicy.confidentLanguage(code: "fi", logProbability: 0.95, supportedCodes: supported))
        assertNil(MeetingLanguageDetectionPolicy.confidentLanguage(code: "fi", logProbability: .nan, supportedCodes: supported))
        assertNil(MeetingLanguageDetectionPolicy.confidentLanguage(code: "fi", logProbability: -.infinity, supportedCodes: supported))
        assertNil(MeetingLanguageDetectionPolicy.confidentLanguage(code: "fi", logProbability: nil, supportedCodes: supported))
        assertNil(MeetingLanguageDetectionPolicy.confidentLanguage(code: "xx", logProbability: 0, supportedCodes: supported))
    }
    runSuite("A meeting locks only consistent independent confident windows") {
        assertEqual(MeetingLanguageDetectionPolicy.resolve([]), .uncertain)
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["fi"]), .uncertain)
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["fi", "fi"]), .detected("fi"))
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["fi", "fi", "fi"]), .detected("fi"))
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["fi", nil]), .uncertain)
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["fi", "fi", nil]), .uncertain, "One weak sample prevents locking even when two others agree")
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["fi", "en"]), .multilingual)
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["fi", nil, "en"]), .multilingual)
        assertEqual(MeetingLanguageDetectionPolicy.resolve([nil, nil]), .uncertain)
        assertEqual(MeetingLanguageDetectionPolicy.resolve(["en", "en"]), .detected("en"), "A later job is independent of the earlier Finnish job")
    }
}
