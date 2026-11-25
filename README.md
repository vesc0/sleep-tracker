# Sleep tracker

Sleep tracker is a native SwiftUI app for iPhone that saves short clips of snoring, sleep talking, and coughing during each session.

## Run on your iPhone

1. Open `SleepTracker.xcodeproj` in Xcode.
2. Select the SleepTracker target. In Signing & Capabilities, choose your Apple development team. If Xcode asks for a unique bundle identifier, change it there.
3. Select your iPhone as the run destination and press Run. Allow microphone access when you tap **Start listening**.

## How audio is handled

AVAudioEngine records microphone audio in roughly eight-second mono segments at 16 kHz by default (44.1 kHz in High quality), including while the phone is locked. After you end the session, Apple Sound Analysis classifies the segments while Sleep tracker is open. If you leave during analysis or a segment fails to analyze, you can use **Analyze remaining audio** in that session in History. A segment is kept when snoring, speech, or coughing is the top label in at least one classification window with confidence of at least 0.55. A clip can have multiple labels. The **Sleep talking** label is based on detected speech. The confidence threshold needs tuning against real bedside audio. Only enabled labels count. The optional full recording saves an additional continuous audio file, including quiet periods. Pending audio and retained clips stay on the iPhone and are excluded from iCloud backup. Deleting a session deletes both.

History and Trends group matching classification windows into episodes. Initial pause allowances are 12 seconds for snoring, four for speech, and three for coughing. Episode length includes these pauses. Sound totals count only the estimated detected time, merging overlapping windows of the same type. Editing or dismissing a clip updates both screens. Older clips and newly assigned labels use the full clip as their timing estimate.

New recordings keep one level summary per segment, including quiet segments. Average level uses duration-weighted mean-square amplitude. Quiet and typical levels use the 10th and 50th percentiles of segment power. Peak uses the highest sample magnitude. Episode details summarize the contributing clips and compare their average to the quieter segments within a minute on either side. All levels are relative to digital full scale (dBFS) and depend on phone placement. Previously discarded audio has no level history.

The live timer shows elapsed session time. Saved duration excludes microphone gaps. With automatic resumption enabled, the app checkpoints an interruption, waits for iOS to release the microphone, and restarts the input in the same session. History shows the gap and the reason iOS supplied. The app estimates sleep duration from recorded time.

Settings includes weekly local reminders, recording options, and audio management. Seven- or 30-day retention removes audio from analyzed sessions while preserving Trends and notes. Export to Files saves one folder per session with JSON metadata and optional available CAF audio.

The checked-in Xcode project is ready to open. If you change `project.yml` or add source files outside Xcode, you can regenerate the project with `xcodegen generate`.
