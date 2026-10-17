// CallSpeakerAXNode.swift
// A plain copy of one Accessibility element and its children, read from a
// call app's meeting window by `CallSpeakerAXTreeReader` and parsed by
// `CallSpeakerTileParser`. Foundation only, so parsers and their JSON
// fixtures (Tests/Fixtures/CallSpeaker/) never need a live app.
//
// Privacy: labels and values hold participant names. A tree lives in memory
// for one poll and is dropped; never log, store or send it.

import Foundation

struct CallSpeakerAXNode: Codable, Equatable, Sendable {
    /// Longest `value` kept. Tile names are short; long values are editors or
    /// transcripts we don't want to hold.
    static let maxValueLength = 200

    var role: String?
    var subrole: String?
    var roleDescription: String?
    var title: String?
    /// `AXDescription` (a web page's aria-label lands here).
    var description: String?
    /// `AXValue`, strings only, cut to `maxValueLength`.
    var value: String?
    /// `AXIdentifier`.
    var identifier: String?
    /// `AXDOMIdentifier` (web and Electron apps).
    var domIdentifier: String?
    /// `AXDOMClassList` (web and Electron apps).
    var domClassList: [String]
    var children: [CallSpeakerAXNode]

    init(
        role: String? = nil,
        subrole: String? = nil,
        roleDescription: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        domIdentifier: String? = nil,
        domClassList: [String] = [],
        children: [CallSpeakerAXNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.title = title
        self.description = description
        self.value = value.map { String($0.prefix(Self.maxValueLength)) }
        self.identifier = identifier
        self.domIdentifier = domIdentifier
        self.domClassList = domClassList
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case role, subrole, roleDescription, title, description, value
        case identifier, domIdentifier, domClassList, children
    }

    /// Fixtures leave out whatever an element doesn't have.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            role: try container.decodeIfPresent(String.self, forKey: .role),
            subrole: try container.decodeIfPresent(String.self, forKey: .subrole),
            roleDescription: try container.decodeIfPresent(String.self, forKey: .roleDescription),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            value: try container.decodeIfPresent(String.self, forKey: .value),
            identifier: try container.decodeIfPresent(String.self, forKey: .identifier),
            domIdentifier: try container.decodeIfPresent(String.self, forKey: .domIdentifier),
            domClassList: try container.decodeIfPresent([String].self, forKey: .domClassList) ?? [],
            children: try container.decodeIfPresent([CallSpeakerAXNode].self, forKey: .children) ?? []
        )
    }

    /// The element's text in the order a screen reader would prefer it:
    /// description (aria-label), then title, then a string value. Empties
    /// are skipped.
    var labels: [String] {
        [description, title, value].compactMap { text in
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
