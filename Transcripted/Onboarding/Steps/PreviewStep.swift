import SwiftUI

/// Preview step - Shows a realistic multi-speaker transcript preview
/// Aesthetic: "Aha moment" - users see what their meetings will look like
/// Phase: Between How It Works (step 2) and Permissions (step 3)
@available(macOS 26.0, *)
struct PreviewStep: View {
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 15
    @State private var visibleLines: Int = 0
    
    // Sample transcript lines with realistic meeting content
    private let transcriptLines: [(speaker: String, text: String, color: Color)] = [
        ("Sarah", "Great, let's go through the project update. I've been working on the new design system.", .terracotta),
        ("Mike", "Yeah, I've been reviewing the latest mockups. The new navigation is much cleaner.", .processingPurple),
        ("Sarah", "I'm especially happy with how the dark mode implementation turned out.", .terracotta),
        ("Mike", "Totally. The contrast ratios are perfect for accessibility.", .processingPurple),
        ("Sarah", "Let's schedule a follow-up for Friday to finalize the timeline.", .terracotta),
        ("Mike", "Sounds good. I'll send out the calendar invite now.", .processingPurple)
    ]
    
    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Header
            VStack(spacing: Spacing.sm) {
                Text("Here is what your meetings will look like")
                    .font(.displayMedium)
                    .foregroundColor(.charcoal)
                
                Text("Real transcript with speaker diarization")
                    .font(.bodyLarge)
                    .foregroundColor(.softCharcoal)
            }
            .opacity(titleOpacity)
            .offset(y: titleOffset)
            .padding(.top, Spacing.lg)
            
            // Transcript preview card
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(0..<transcriptLines.count, id: \.self) { index in
                    HStack(spacing: Spacing.sm) {
                        // Speaker label with colored circle
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack(spacing: Spacing.xs) {
                                Circle()
                                    .fill(transcriptLines[index].color)
                                    .frame(width: 8, height: 8)
                                
                                Text(transcriptLines[index].speaker)
                                    .font(.headingSmall)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.charcoal)
                            }
                            .opacity(index < visibleLines ? 1 : 0)
                            .offset(y: index < visibleLines ? 0 : 10)
                            
                            Text(transcriptLines[index].text)
                                .font(.transcript)
                                .foregroundColor(.softCharcoal)
                                .opacity(index < visibleLines ? 1 : 0)
                                .offset(y: index < visibleLines ? 0 : 10)
                        }
                        .animation(.smooth.delay(Double(index) * 0.2), value: visibleLines)
                    }
                    .opacity(index < visibleLines ? 1 : 0)
                    .offset(y: index < visibleLines ? 0 : 20)
                }
            }
            .padding(Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(Color.warmCream)
                    .shadow(color: .black.opacity(0.05), radius: 16, y: 4)
            )
            .padding(.horizontal, Spacing.xl)
            
            Spacer()
        }
        .onAppear {
            animateIn()
        }
    }
    
    private func animateIn() {
        // Title animation
        withAnimation(.smooth.delay(0.1)) {
            titleOpacity = 1.0
            titleOffset = 0
        }
        
        // Staggered transcript lines
        for i in 0..<transcriptLines.count {
            withAnimation(.smooth.delay(Double(i) * 0.3 + 0.5)) {
                visibleLines = i + 1
            }
        }
    }
}
