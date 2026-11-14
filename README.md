# Sleep tracker

Sleep tracker is a native SwiftUI app for iPhone that saves short clips of snoring, sleep talking, and coughing during each session.

## Run on your iPhone

1. Open `SleepTracker.xcodeproj` in Xcode.
2. Select the SleepTracker target. In Signing & Capabilities, choose your Apple development team. If Xcode asks for a unique bundle identifier, change it there.
3. Select your iPhone as the run destination and press Run. Allow microphone access when you tap **Start listening**.

## How audio is handled

AVAudioEngine records microphone audio in roughly eight-second mono segments at 16 kHz, including while the phone is locked. After you end the session, Apple Sound Analysis classifies the segments while Sleep tracker is open. If you leave during analysis or a segment fails to analyze, you can use **Analyze remaining audio** in that session in History. A segment is kept when snoring, speech, or coughing is the top label in at least one classification window with confidence of at least 0.55. A clip can have multiple labels. The **Sleep talking** label is based on detected speech. The confidence threshold needs tuning against real bedside audio. Other segments are discarded after analysis. Pending audio and retained clips stay on the iPhone and are excluded from iCloud backup. Deleting a session deletes both.

The session timer measures audio monitoring time. The app does not estimate time asleep or diagnose sleep conditions. If iOS interrupts microphone access, Sleep tracker saves the processed portion and marks the session incomplete.

The checked-in Xcode project is ready to open. If you change `project.yml` or add source files outside Xcode, you can regenerate the project with `xcodegen generate`.
