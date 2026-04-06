// MenuBarModelDownloadView.swift
// Model download progress for the local Parakeet speech model during first launch

import AppKit

@MainActor
final class MenuBarModelDownloadView: NSView {
    private let voiceRow = ModelDownloadRow()
    private let footerLabel = NSTextField(labelWithString: "Models download once and stay local on your Mac.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor

        addSubview(voiceRow)

        footerLabel.font = NSFont.systemFont(ofSize: 10)
        footerLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(footerLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let rowH: CGFloat = 36
        let footerH: CGFloat = 14
        voiceRow.frame = NSRect(x: pad, y: bounds.height - pad - rowH, width: bounds.width - pad * 2, height: rowH)
        footerLabel.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: footerH)
    }

    func update(voiceModelLoaded: Bool, voiceState: ParakeetModelState) {
        voiceRow.update(label: "Voice model", detail: "Parakeet CoreML (~600 MB)",
                        isReady: voiceModelLoaded, state: voiceState)
    }

    var intrinsicHeight: CGFloat { 64 }
}

private final class ModelDownloadRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let progressBar = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)

        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(nameLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 10)
        detailLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(detailLabel)

        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = MenuTokens.textSecondaryNS
        statusLabel.alignment = .right
        addSubview(statusLabel)

        if let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done") {
            checkmark.image = img
            checkmark.contentTintColor = MenuTokens.statusGreenNS
        }
        checkmark.isHidden = true
        addSubview(checkmark)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1.0
        progressBar.isHidden = true
        addSubview(progressBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        nameLabel.frame = NSRect(x: 0, y: bounds.height - 14, width: bounds.width * 0.6, height: 14)
        statusLabel.frame = NSRect(x: bounds.width * 0.6, y: bounds.height - 14, width: bounds.width * 0.4, height: 14)
        checkmark.frame = NSRect(x: bounds.width - 16, y: bounds.height - 14, width: 14, height: 14)
        detailLabel.frame = NSRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 12)
        progressBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 6)
    }

    func update(label: String, detail: String, isReady: Bool, state: Any) {
        nameLabel.stringValue = label
        detailLabel.stringValue = detail
        statusLabel.textColor = MenuTokens.textSecondaryNS
        statusLabel.toolTip = nil

        if isReady {
            checkmark.isHidden = false
            statusLabel.isHidden = true
            progressBar.isHidden = true
            return
        }

        checkmark.isHidden = true
        statusLabel.isHidden = false

        if let ps = state as? ParakeetModelState {
            switch ps {
            case .downloading(let p):
                statusLabel.stringValue = "\(Int(p * 100))%"
                progressBar.isHidden = false
                progressBar.doubleValue = p
            case .loading:
                statusLabel.stringValue = "Loading..."
                progressBar.isHidden = true
            case .failed(let reason):
                statusLabel.stringValue = "Failed"
                statusLabel.textColor = NSColor.systemRed
                statusLabel.toolTip = reason
                progressBar.isHidden = true
            default:
                statusLabel.stringValue = "Waiting..."
                progressBar.isHidden = true
            }
        }
    }
}
