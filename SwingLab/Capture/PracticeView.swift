import SwiftUI
import SwiftData

/// The Practice tab: live camera, auto-detects when a swing finishes, and
/// speaks the result a couple seconds later. Reuses `CameraPreview` from
/// `RecordView.swift` — same live-preview mechanism, different capture
/// session underneath (`LivePracticeSession`'s, not `CameraRecorder`'s).
struct PracticeView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var session: LivePracticeSession?
    @State private var showTips = false

    @AppStorage("defaultView") private var defaultView = CameraViewType.faceOn.rawValue
    @AppStorage("defaultHandedness") private var defaultHandedness = Handedness.right.rawValue
    @AppStorage("defaultShotType") private var defaultShotType = ShotType.fullSwing.rawValue
    @AppStorage("defaultClub") private var defaultClub = GolfClub.sevenIron.rawValue

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let session {
                    content(session: session)
                } else {
                    ProgressView("Starting camera…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            guard session == nil else { return }
            let live = LivePracticeSession(context: context, profile: profileStore.profile)
            live.view = CameraViewType(rawValue: defaultView) ?? .faceOn
            live.handedness = Handedness(rawValue: defaultHandedness) ?? .right
            live.shotType = ShotType(rawValue: defaultShotType) ?? .fullSwing
            live.club = GolfClub(rawValue: defaultClub)
            session = live
            live.start()
        }
        .onDisappear {
            session?.stop()
            session = nil
        }
    }

    @ViewBuilder
    private func content(session: LivePracticeSession) -> some View {
        switch session.state {
        case .idle, .requestingAccess:
            ProgressView("Starting camera…").tint(.white).foregroundStyle(.white)
        case .denied:
            permissionDeniedView
        case .failed(let message):
            Text(message)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding()
        case .watching, .analyzing, .spoke:
            CameraPreview(session: session.session)
                .ignoresSafeArea()
            ghostAlignmentGuide
            overlayUI(session: session)
        }
    }

    /// A simple standing-figure silhouette as an alignment reference —
    /// deliberately not the fully custom vector golfer illustration the
    /// plan describes for later polish; this placeholder gets the actual
    /// behavior (get golfer roughly centered and full-height before
    /// swinging) in front of the developer now rather than waiting on artwork.
    private var ghostAlignmentGuide: some View {
        Image(systemName: "figure.golf")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white.opacity(0.25))
            .frame(height: 420)
            .allowsHitTesting(false)
    }

    private func overlayUI(session: LivePracticeSession) -> some View {
        VStack {
            statusBanner(session: session)
                .padding(.top, 8)
            Spacer()
            tipsDisclosure
                .padding(.bottom, 24)
        }
        .padding(.horizontal)
    }

    private func statusBanner(session: LivePracticeSession) -> some View {
        VStack(spacing: 6) {
            Text(headline(for: session.state))
                .font(.headline)
                .foregroundStyle(.white)
            Text("Setup 8 feet away, full body in frame. Swing once — we'll catch it and read the result back to you.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            if case .spoke(let text) = session.state {
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.fairway)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func headline(for state: LivePracticeSession.State) -> String {
        switch state {
        case .watching: return "Watching for your swing…"
        case .analyzing: return "Reading that swing…"
        case .spoke: return "Here's what I saw"
        default: return ""
        }
    }

    private var tipsDisclosure: some View {
        DisclosureGroup("Swing Not Detected? Try These Tips", isExpanded: $showTips) {
            VStack(alignment: .leading, spacing: 8) {
                tipRow("Take only one swing per take — a practice swing right before the real one can confuse detection. Waggle before you start, not a full rehearsal swing.")
                tipRow("Stand roughly 8 feet from the phone with your whole body in frame, address to finish.")
                tipRow("Pause briefly at address before you start your backswing, and hold your finish for a second after.")
                tipRow("Good, even light helps — avoid standing with a bright window directly behind you.")
            }
            .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 4)).padding(.top, 6)
            Text(text).font(.caption).foregroundStyle(.white.opacity(0.85))
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.largeTitle)
                .foregroundStyle(.white)
            Text("Camera access is off")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Enable it in Settings → SwingLab → Camera to use Practice mode. You can still record or import videos from the Swings tab.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
