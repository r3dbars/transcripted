import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared by the persistent sidebar action and a capture's Report issue menu.
struct FeedbackComposerView: View {
    @ObservedObject var model: FeedbackComposerModel
    let onClose: () -> Void
    let onPickerClosed: () -> Void
    @State private var showsDiagnostics = false
    @State private var dropTargeted = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)

            if model.step == .sent {
                success
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.step == .compose { editor } else { review }
                    }
                    .padding(1)
                }
                .frame(maxHeight: 420)
                if let error = model.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("transcripted.feedback.error")
                        if model.step == .review {
                            Button(model.copiedReport ? "Report copied" : "Copy report") { model.copyReport() }
                                .buttonStyle(.link)
                            Text("Email the copied report to help@transcripted.app. Attach screenshots separately.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(LibraryTokens.contentBackground)
        .accessibilityIdentifier("transcripted.feedback.form")
        .onAppear { messageFocused = model.step == .compose }
        .onDrop(of: [UTType.fileURL.identifier] + FeedbackAttachment.imageTypes, isTargeted: $dropTargeted) { providers in
            model.addScreenshotProviders(providers)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.step == .review ? "Review your report" : "Feedback")
                    .font(.system(size: 21, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SidebarQuietButtonStyle())
                .help("Close feedback. Your draft stays here.")
                .accessibilityLabel("Close feedback")
            }
            if model.step == .review {
                Text("This will go to help@transcripted.app.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                if model.message.isEmpty {
                    Text("Tell me about it…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.message)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(3)
                    .focused($messageFocused)
                    .accessibilityLabel("Your feedback")
                    .accessibilityIdentifier("transcripted.feedback.message")
            }
            .frame(height: 124)
            .background(LibraryTokens.raisedFill)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(LibraryTokens.raisedStroke))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if model.message.utf16.count > 4_000 {
                Text("Please keep your feedback under 4,000 characters.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextField("Email for a reply (optional)", text: $model.replyEmail)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("transcripted.feedback.reply-email")

            screenshots

            Toggle("Include diagnostics and logs", isOn: $model.includeDiagnostics)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("transcripted.feedback.include-diagnostics")

            DisclosureGroup("What’s included?", isExpanded: $showsDiagnostics) {
                Text("\(model.reportContextSummary)\nYour message, optional reply email, and \(model.attachments.count) chosen image\(model.attachments.count == 1 ? "" : "s").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Text(model.includeDiagnostics ? model.diagnosticPreview : "Diagnostics and logs are not included.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                Text("Only the listed details are sent after review. No raw log files, transcripts, audio, file paths, or device names are attached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: chooseScreenshots) {
                HStack(spacing: 8) {
                    Image(systemName: dropTargeted ? "arrow.down.circle" : "paperclip")
                    Text(model.isLoadingAttachments ? "Preparing…" : dropTargeted ? "Drop images" : "Add or drop images")
                        .font(.system(size: 12))
                    Spacer()
                    if model.isLoadingAttachments { ProgressView().controlSize(.small) }
                    Text("\(model.attachments.count)/3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(SidebarQuietButtonStyle())
            .background(dropTargeted ? Color.orange.opacity(0.10) : LibraryTokens.raisedFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Color.orange : LibraryTokens.raisedStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .disabled(model.attachments.count >= 3 || model.isLoadingAttachments)
            .help("PNG, JPEG, HEIC, or TIFF. Up to 3 images.")
            .accessibilityLabel("Attach images")
            .accessibilityIdentifier("transcripted.feedback.attach")
            if !model.attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.attachments) { attachment in
                        VStack(spacing: 4) {
                            if let image = NSImage(data: attachment.data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 96, height: 60)
                            }
                            Button("Remove") { model.removeScreenshot(attachment.id) }
                                .font(.caption)
                                .buttonStyle(.link)
                                .accessibilityLabel("Remove screenshot \(model.attachments.firstIndex(where: { $0.id == attachment.id }).map { $0 + 1 } ?? 1)")
                        }
                        .padding(5)
                        .background(LibraryTokens.raisedFill, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.reportContextSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.message)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !model.replyEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Reply to: \(model.replyEmail)")
                    .font(.callout)
            }
            if model.includeDiagnostics {
                Text(model.diagnosticPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("Diagnostics not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.attachments.isEmpty {
                Text("\(model.attachments.count) screenshot\(model.attachments.count == 1 ? "" : "s") attached")
                    .font(.callout)
                HStack(spacing: 8) {
                    ForEach(model.attachments) { attachment in
                        if let image = NSImage(data: attachment.data) {
                            Image(nsImage: image)
                                .resizable().scaledToFit()
                                .frame(width: 112, height: 80)
                        }
                    }
                }
            }
            Text("Your message and screenshots may contain private information. Only send what you want support to see.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(model.step == .review ? "Back" : "Cancel") {
                if model.step == .review { model.edit() } else { onClose() }
            }
            .buttonStyle(.bordered)
            .disabled(model.isSending)
            Spacer()
            Button(model.isSending ? "Sending…" : model.step == .review ? "Send report" : "Review report") {
                if model.step == .review {
                    Task { await model.send() }
                } else {
                    model.review()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(model.step == .compose ? !model.canReview : model.isSending)
            .accessibilityIdentifier("transcripted.feedback.primary")
        }
        .padding(.top, 16)
    }

    private var success: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Thanks—your report was sent.", systemImage: "checkmark.circle")
                .font(.headline)
            Text("It’s on its way to Transcripted support.\(model.replyEmail.isEmpty ? "" : " We can reply to the email you included.")")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let receiptID = model.receiptID {
                Text("Reference: \(receiptID)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Button("Write another") { model.reset() }
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .accessibilityIdentifier("transcripted.feedback.success")
    }

    private func chooseScreenshots() {
        let picker = NSOpenPanel()
        picker.title = "Attach screenshots"
        picker.prompt = "Attach"
        picker.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.begin { response in
            if response == .OK { model.addScreenshots(picker.urls) }
            // The system picker deactivates a transient popover. Bring the
            // retained draft back when it closes, including on Cancel.
            Task { @MainActor in
                await Task.yield()
                onPickerClosed()
            }
        }
    }
}
