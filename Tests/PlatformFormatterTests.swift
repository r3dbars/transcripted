// PlatformFormatterTests.swift
// Tests for PlatformFormatter.postProcess() and detect()

import AppKit

func testPlatformFormatter() {
    runSuite("PlatformFormatter.postProcess — slack bold fix") {
        let result = PlatformFormatter.slack.postProcess("This is **bold** text")
        assertEqual(result, "This is *bold* text", "should convert double to single asterisks")
    }

    runSuite("PlatformFormatter.postProcess — slack header strip") {
        let result = PlatformFormatter.slack.postProcess("## Header\nSome text")
        assertEqual(result, "Header\nSome text", "should strip markdown headers")
    }

    runSuite("PlatformFormatter.postProcess — slack combined") {
        let result = PlatformFormatter.slack.postProcess("## Title\n**Important** note")
        assertEqual(result, "Title\n*Important* note")
    }

    runSuite("PlatformFormatter.postProcess — imessage strip all markdown") {
        let result = PlatformFormatter.imessage.postProcess("**Bold** and *italic* and _underline_ text")
        assertFalse(result.contains("**"), "no double asterisks")
        assertFalse(result.contains("*"), "no single asterisks")
        assertFalse(result.contains("_"), "no underscores")
        assertTrue(result.contains("Bold"), "text preserved")
        assertTrue(result.contains("italic"), "text preserved")
    }

    runSuite("PlatformFormatter.postProcess — imessage strip headers at line start") {
        let result = PlatformFormatter.imessage.postProcess("## Header\nSome text")
        assertFalse(result.hasPrefix("##"), "header stripped from line start")
        assertTrue(result.contains("Header"), "header text preserved")
    }

    runSuite("PlatformFormatter.postProcess — generic passthrough") {
        let input = "**Bold** and *italic* and ## Header"
        let result = PlatformFormatter.generic.postProcess(input)
        assertEqual(result, input, "generic should pass through unchanged")
    }

    runSuite("PlatformFormatter.postProcess — email passthrough") {
        let input = "**Bold** and *italic*"
        let result = PlatformFormatter.email.postProcess(input)
        assertEqual(result, input, "email should pass through unchanged")
    }

    runSuite("PlatformFormatter.detect — nil app") {
        let result = PlatformFormatter.detect(from: nil)
        assertEqual(result, .generic, "nil app should detect as generic")
    }
}
