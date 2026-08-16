import SwiftUI

/// How-to-film guidance. Shown on first launch and from the ? button.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    tip(icon: "ruler",
                        title: "Stand back about 10–15 feet",
                        body: "Your whole body plus the club needs to stay in frame from address all the way to the finish.")

                    tip(icon: "iphone.gen3",
                        title: "Camera at hands height",
                        body: "Prop the phone on a bag or alignment stick roughly level with your hands at address — not on the ground, not at head height.")

                    tip(icon: "figure.stand",
                        title: "Face-On",
                        body: "Camera directly in front of your chest. Best for shoulder turn, hip turn, X-factor, head stability and sway.")

                    tip(icon: "arrow.up.forward",
                        title: "Down-the-Line",
                        body: "Camera directly behind you, looking down your target line. Best for spine angle, posture, early extension and swing plane.")

                    tip(icon: "sun.max",
                        title: "Good light, plain background",
                        body: "Body tracking works best with even light and clear separation between you and what's behind you.")

                    tip(icon: "timer",
                        title: "One swing per clip",
                        body: "Trim to a single swing with a beat of stillness before and after — that's how SwingLab finds address and finish.")

                    tip(icon: "lock.shield",
                        title: "Everything stays on your phone",
                        body: "Pose detection, scoring and coaching all run on-device. No account, no uploads, works in airplane mode.")
                }
                .padding()
            }
            .navigationTitle("How to Film")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got it") { dismiss() }.bold()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "figure.golf")
                .font(.largeTitle)
                .foregroundStyle(Theme.fairway)
            Text("Get clean footage and the numbers get honest.")
                .font(.title3.bold())
        }
        .padding(.bottom, 4)
    }

    private func tip(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.fairway)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
