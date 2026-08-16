# SwingLab

An iPhone golf swing analyzer. Film a swing, and SwingLab breaks it down position by
position — drawing lines and angles on the video, scoring each checkpoint against ideal
biomechanical ranges, and writing plain-language coaching.

Everything runs **on your iPhone**. No account, no backend, no API keys, no internet.
It works in airplane mode.

---

## What it does

**Capture** — record in-app at the highest frame rate your iPhone supports (120 or 240 fps
slow motion), or import any video from your camera roll.

**Find the swing** — a range-session clip is mostly walking, setting up, waggling and
reacting. SwingLab first skims the whole clip cheaply to locate the actual swing, then
analyses only that window at full frame rate. If there's more than one swing it lists them
and lets you pick.

**Detect** — Apple's Vision framework tracks your body joints in every frame. SwingLab then
finds the key positions: Address, Takeaway, Halfway Back, Top, Transition, Delivery, Impact,
Finish. The top is found where the club changes direction, and impact where your hands return
to address height — not simply "the fastest frame", which a quick follow-through steals. Each
position carries a confidence, and the app tells you when it isn't sure rather than presenting
a guess as fact. Jump-to buttons cover the five you look at most, and anything can be nudged
by hand.

**Measure rotation in 3D** — on capable iPhones, `VNDetectHumanBodyPose3DRequest` measures
shoulder and hip turn directly from joints with real depth, rather than inferring them from
how narrow your shoulders look on a flat image. It runs on the key frames only, since the 3D
request is far heavier than the 2D one, and falls back to the estimate when unavailable.

**Measure** — line and angle overlays are drawn on each position:

| Metric | What it means | Best camera view |
|---|---|---|
| Spine Angle | Forward tilt from vertical, set at address | Down-the-Line |
| Posture Change | Spine-angle drift vs address (early extension) | Down-the-Line |
| Shoulder Turn | Shoulder rotation at the top | Face-On |
| Hip Turn | Hip rotation at the top | Face-On |
| X-Factor | Shoulder turn minus hip turn — stored power | Face-On |
| Head Drift | Sideways head movement, in inches | Face-On |
| Hip Sway | Sideways hip slide instead of rotation | Face-On |
| Plane Deviation | Hands' distance off the swing-plane line | Down-the-Line |

Each gets a measured value, the ideal range, a good/needs-work status, and feeds a weighted
overall score out of 100.

**Diagnose** — beyond the raw numbers, SwingLab names what's actually going wrong: over the
top, early extension, casting, swaying, sliding, reverse pivot, hanging back, and dropping or
standing up through impact. Each one comes with a plain explanation, a feel, and a drill.

Fat and thin contact are different in kind, and the app is explicit about it: where the club
bottoms out isn't visible to a camera watching your body, so those are reported as
**tendencies** inferred from the body pattern that causes them, at reduced confidence, clearly
labelled. You can tag what actually happened to the shot (flushed, fat, thin, topped, slice,
hook, pull, push, shank) and the coaching will re-rank its findings to lead with the fault that
explains your miss. Tagging never invents a fault the swing doesn't show — it only re-weights
what was already found.

**Coach** — the diagnosis is handed to Apple's on-device Foundation Models LLM, which writes
specific, encouraging tips and explains how the named fault produces your particular miss. On
iPhones without Apple Intelligence, a built-in rules engine produces equivalent coaching, so
the feature never goes dark.

**Compare** — side by side against an abstract "ModelPro" stick-figure ideal for that
position (with a ghost-overlay mode), or against any of your own swings you've marked as a
reference.

**Track** — every swing is saved locally with trend charts of your overall score and any
individual metric over time.

---

## Setup — start here

You need a Mac and an iPhone. Total time is about an hour, most of it waiting on a download.

### Step 1 — Install Xcode

Xcode is already installed on this Mac. The one thing still outstanding is pointing the
command line at it — Terminal still defaults to the older Command Line Tools, so `xcodebuild`
fails until you run this once. It needs your Mac password:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

It will ask for your Mac login password (nothing is shown as you type — that's normal).

Verify it worked:

```bash
xcodebuild -version
```

You should see a version number rather than an error.

### Step 2 — Open the project

```bash
open ~/SwingLab/SwingLab.xcodeproj
```

Xcode will open. Give it a minute to finish indexing (progress shows in the top bar).

### Step 3 — Try it in the Simulator first

This confirms everything builds before you involve your phone.

1. In the toolbar at the top, next to the app name, click the device selector.
2. Choose any **iPhone 17** simulator.
3. Press the **▶ (Play)** button, or hit **⌘R**.

The Simulator launches and SwingLab opens. The simulator has no camera, so use **Import** to
load a swing video. (You can drag a video file from Finder onto the Simulator window to add
it to that fake phone's photo library first.)

### Step 4 — Sign the app with your Apple ID

To run on a real iPhone, Apple requires the app be signed. A **free** Apple ID works.

1. Xcode menu → **Settings…** → **Accounts** tab.
2. Click **＋** → **Apple ID** → sign in with your regular Apple ID.
3. Close Settings.
4. In the left sidebar, click the blue **SwingLab** project icon at the very top.
5. Select the **SwingLab** target, then the **Signing & Capabilities** tab.
6. Check **Automatically manage signing**.
7. Under **Team**, choose your name (it'll say "Personal Team").

If it complains that the bundle identifier is already taken, change **Bundle Identifier**
from `com.yourname.swinglab` to something unique like `com.yourname.swinglab2`.

### Step 5 — Put it on your iPhone

1. Connect your iPhone to the Mac with a cable.
2. Unlock the phone. It will ask **Trust This Computer?** — tap **Trust** and enter your
   passcode.
3. Back in Xcode, click the device selector in the toolbar and pick **your iPhone** (it
   appears at the top of the list, above the simulators).
4. Press **▶** (⌘R).

The first run will fail with an "Untrusted Developer" message on the phone. That's expected:

5. On your **iPhone**, go to **Settings → General → VPN & Device Management**.
6. Tap your Apple ID under "Developer App" → tap **Trust**.
7. Back in Xcode, press **▶** again.

SwingLab launches. Grant **Camera** and **Photos** access when it asks.

### Step 6 — Film your first swing

Tap the **?** in the top-right for the filming guide. The short version:

- Stand back **10–15 feet** so your whole body and the club stay in frame.
- Put the phone at **hands height** — prop it on your bag or an alignment stick. Not on the
  ground, not at head height. This matters a lot for the angles being honest.
- **Face-On** = camera in front of your chest. **Down-the-Line** = camera behind you looking
  down your target line.
- Good even light, plain background.
- **One swing per clip**, with a moment of stillness before and after. That stillness is how
  SwingLab finds your address and finish frames.

---

## Things to know

**The 7-day expiry.** With a free Apple ID, apps you install this way stop working after 7
days. To renew: plug the phone in, open the project in Xcode, press ▶ again. That's it —
your saved swings are not lost. A paid Apple Developer account ($99/year) extends this to a
year, but for personal use the weekly re-run is usually fine.

**Wireless installs.** After the first cable install, go to Xcode → **Window → Devices and
Simulators**, select your iPhone, and check **Connect via network**. From then on you can
run without the cable, as long as both are on the same Wi-Fi.

**On-device AI coaching** needs an Apple-Intelligence-capable iPhone (15 Pro or 16 and newer)
running iOS 26, with Apple Intelligence turned on in Settings. On any other iPhone the app
automatically uses its built-in rules coach instead — same structure of advice, just written
from a fixed playbook rather than generated. You'll see which one is active in
**Settings → About → Coaching**.

**Calibrating the ideal ranges.** Every target range lives in **Settings** and is editable,
and each one carries a plain-language description of what it actually measures so you're never
guessing what a number controls. They're seeded with model-pro values in the spirit of the
position-by-position methodology from *Swing Like a Pro*, but they're starting points — this is
your personal tool, so tune them as you learn what's realistic and useful for your swing. You
can also change how heavily each metric counts toward the overall score.

Each range is a low/high pair plus a weight controlling how much it counts toward your overall
score. Reset returns everything to the seeded defaults.

**Film in Slo-Mo if you can.** At 30 fps your entire downswing is only 7–9 frames, which caps
how precisely impact and anything measured at the strike can be pinned down. SwingLab detects
the frame rate and lowers its confidence accordingly rather than pretending otherwise. 120 or
240 fps makes a real difference.

**Head movement is shown, not just scored.** The overlay draws two circles: a dashed one where
your head was at address and a solid one where it is now, with an arrow between them. It turns
amber once the movement passes the limit you've set, so the number and the picture always agree.

**What the camera can and can't see.** There's no club or ball tracking — SwingLab watches your
body. Spine angle, posture change, head drift and hip sway are measured directly and are
trustworthy. Shoulder and hip turn are measured properly in 3D on capable iPhones, and estimated
from foreshortening otherwise. Fat and thin are *inferences* from body pattern, never
measurements of the strike, and the app says so every time it mentions them.

**A note on camera angle.** A true face-on view means the camera square to your chest. If it's
off to one side, your forward bend over the ball projects into the image as sideways lean.
SwingLab measures the things that matter as changes from your address position, which cancels
most of that out, but square footage still gives the best numbers.

---

## Project layout

```
SwingLab/
├── project.yml                     XcodeGen spec (regenerates the .xcodeproj)
├── SwingLab.xcodeproj              The Xcode project — open this
├── tools/make_icon.swift           Regenerates the app icon PNG
├── SwingLab/
│   ├── SwingLabApp.swift           App entry point + tab bar
│   ├── Models/
│   │   ├── Enums.swift             Positions, metrics, shot types, views
│   │   ├── AnalysisModels.swift    Pose frames, metric results, scoring
│   │   ├── ModelProProfile.swift   Editable ideal ranges + storage
│   │   └── SwingRecord.swift       SwiftData record for a saved swing
│   ├── Geometry/SwingGeometry.swift    Pure angle & line math (aspect-corrected)
│   ├── Detection/
│   │   ├── SwingWindowScanner.swift    Finds the swing in a long clip
│   │   ├── SwingSignal.swift           Time-based motion signal
│   │   └── PositionDetector.swift      Auto key-frame finder
│   ├── Pose/
│   │   ├── VideoPoseExtractor.swift    Vision body-pose over video
│   │   ├── VideoOrientation.swift      Rotation handling + uprightness guard
│   │   ├── PoseSpace.swift             Isotropic coordinate correction
│   │   └── Pose3DExtractor.swift       3D rotation on key frames
│   ├── Analysis/
│   │   ├── SwingAnalyzer.swift     Metrics scored vs the profile
│   │   ├── FaultDetector.swift     Named diagnoses + contact tendencies
│   │   └── AnalysisPipeline.swift  Orchestrates the whole run
│   ├── Coaching/
│   │   ├── Coach.swift             On-device LLM coaching
│   │   └── RulesCoach.swift        Deterministic fallback
│   ├── Capture/                    Camera recording + PHPicker video import
│   ├── Persistence/VideoStore.swift    Video files on disk
│   └── UI/
│       ├── LibraryView.swift       Home screen and swing library
│       ├── SetupSheet.swift        Pre-analysis options + progress
│       ├── ResultsView.swift       Scores, overlays, coaching
│       ├── ComparisonView.swift    Side-by-side comparison
│       ├── OverlayCanvas.swift     Lines and angles over a frame
│       ├── ModelProFigure.swift    Abstract ideal stick figure
│       ├── ImportCoordinator.swift Owns the import -> analyse -> results flow
│       ├── ProgressTrendsView.swift    Trend charts
│       ├── SettingsView.swift      Editable ideal ranges
│       └── OnboardingView.swift    How-to-film guide
├── SwingLabTests/                  Unit tests for the math and detection
└── SwingLabUITests/                End-to-end tests driving the real app
```

The layers are deliberately separated: `Geometry`, `PositionDetector`, `SwingAnalyzer`,
`RulesCoach` and the model types are pure Swift with no Apple-framework dependencies, which
is what makes them testable and what keeps the tricky math in one reviewable place.

## Running the tests

In Xcode, press **⌘U**. Or from Terminal:

```bash
xcodebuild test -project ~/SwingLab/SwingLab.xcodeproj -scheme SwingLab -destination 'platform=iOS Simulator,name=iPhone 17'
```

117 tests. The unit suite covers the angle math and its aspect correction, drift-to-inches
scaling, signed geometry for fault detection, head-circle fitting, swing-plane geometry, metric
scoring, key-frame detection against a deliberately messy fixture (walk-in, waggle, pause at the
top, reaction) at 30/60/240 fps, swing-window scanning, the fault detectors and shot-tag
re-ranking, the import state machine across repeated imports, and JSON round trips including
decoding records saved before newer fields existed. The UI suite drives the real app in the
Simulator.

Real-footage verification runs separately: the clips are too large to bundle, so a harness in
the scratchpad symlinks the actual app sources into a macOS package and runs them against real
video, rendering the detected key frames with overlays so alignment can be checked by eye.

## Regenerating the project file

If you add or remove source files outside of Xcode, rebuild the project from `project.yml`:

```bash
cd ~/SwingLab && xcodegen generate
```
