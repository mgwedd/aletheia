# Aletheia behavior reference

The detailed layer under [ACCEPTANCE-CRITERIA.md](ACCEPTANCE-CRITERIA.md): every observable behavior, edge case and exact on-screen message, by theme, with pointers into the source. Read the QA walkthrough first; come here when writing or debugging a fitness function.

IDs are a theme prefix plus a three-digit number (for example EXP-029) and never change once assigned. Each item carries `surface` (ui, background or invariant), `evidence` (repo paths, a pointer for readers and not checked by any gate) and `qa` (the walkthrough check that rolls it up; the acceptance suite's coverage test requires it to name a real check).

| Theme | Count |
|---|---|
| Recording (REC) | 77 |
| Set-aside recordings (SAR) | 15 |
| Voice input (VOI) | 17 |
| Transcription (TRN) | 91 |
| Encryption at rest (ENC) | 50 |
| App lock and privacy shield (LCK) | 23 |
| Audit log (AUD) | 14 |
| Data format and upgrades (DAT) | 12 |
| Doctor and security posture (DOC) | 10 |
| Security guarantees (SEC) | 9 |
| Backups (BAK) | 10 |
| Progress notes (NOT) | 69 |
| Digests (DIG) | 31 |
| Harness/eval (HAR) | 1 |
| Chat & Q&A (CHT) | 69 |
| AI engine & models (AIE) | 45 |
| Patients (PAT) | 47 |
| Sessions (SES) | 37 |
| Search (SRC) | 57 |
| Comments (CMT) | 32 |
| Export & archive (EXP) | 48 |
| Network, privacy invariants & helper (NET) | 30 |
| Updates (UPD) | 28 |
| OS integrations (OSI) | 62 |
| Onboarding & setup (STP) | 27 |
| Settings (SET) | 46 |
| Appearance, accessibility & shortcuts (UX) | 21 |
| Legal & consent (LEG) | 11 |
| Build tiers (BLD) | 17 |
| **Total** | **1017** |

## Recording (REC)

- **REC-001** When the user presses Record Session on a session that has no transcript and no recording, recording starts and the session screen shows a Recording chip, a red dot and an elapsed timer.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:384, Sources/App/Views/SessionDetailView.swift:448, Sources/App/Services/SessionRecorder.swift:233` · `qa: RECORD-01`
- **REC-002** When the user chooses a patient in the menu bar panel and presses Start recording, a new session is created for that patient, recording begins, and the main window comes forward showing that patient.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:268-288, Sources/App/Services/AppModel.swift:548` · `qa: MENUBAR-03`
- **REC-003** When a recording of this session is running, the main window's action bar shows a Stop Recording button, a Pause button and a timer with a red dot.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:428` · `qa: RECORD-01`
- **REC-004** When a recording is running, no control offers to start a second recording, so only one session records at a time.
  `surface: invariant` · `evidence: Sources/App/Views/SessionDetailView.swift:448, Sources/App/Views/RecordingMenuBar.swift:48, Sources/App/Services/SessionRecorder.swift:233` · `qa: RECORD-01`
- **REC-005** When a different session is recording and this session has no transcript or recording, this session's action bar shows "Recording another session" instead of a Record button, with the tooltip "Stop the current recording from the menu bar first".
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:449` · `qa: RECORD-03`
- **REC-006** When a recording is still starting (permission prompts or opening the captures), the Record Session button is disabled with the tooltip "A recording is starting".
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:462, Sources/App/Services/TranscriptionProgress.swift:134` · `qa: RECORD-01`
- **REC-007** When a session already has a transcript or a recording, or is being transcribed or waiting in the transcription queue, no Record button is offered for it.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionProgress.swift:118, Sources/App/Views/SessionDetailView.swift:1556` · `qa: RECORD-03`
- **REC-008** When a recording finishes, the session folder holds the microphone and the call audio as two separate audio files rather than one mixed file.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:444, Sources/App/Services/Store.swift:619, Sources/App/Services/WhisperTranscriber.swift:59` · `qa: RECORD-09`
- **REC-009** When microphone access has been denied, pressing Record does not start a recording and shows "Aletheia doesn't have permission to use the microphone. Open System Settings > Privacy & Security > Microphone and turn it on for Aletheia."
  `surface: ui` · `evidence: Sources/App/Services/MicRecorder.swift:5, Sources/App/Services/SessionRecorder.swift:281` · `qa: RECORD-06`
- **REC-010** When call audio cannot be captured, recording continues with the microphone only and the session pane shows "Only your microphone is being recorded." followed by the reason.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:558, Sources/App/Services/SessionRecorder.swift:319` · `qa: RECORD-05`
- **REC-011** When Record is pressed after an earlier call-audio attempt in this launch failed and access is not known to be granted, call audio is skipped for the session and the pane says "Call audio is off for this session: Screen & System Audio Recording isn't set up for this version of Aletheia. Open Settings > Setup Assistant and choose Allow next to Call audio capture."
  `surface: ui` · `evidence: Sources/App/Services/CallAudioStartPolicy.swift:18, Sources/App/Services/SessionRecorder.swift:319` · `qa: RECORD-05`
- **REC-012** When Record is pressed and call-audio access is not yet known to be granted, the app still tries to start call-audio capture once per launch, which can show the system's screen and audio recording permission dialog.
  `surface: background` · `evidence: Sources/App/Services/CallAudioStartPolicy.swift:24, Sources/App/Services/SessionRecorder.swift:319` · `qa: RECORD-02`
- **REC-013** When call-audio capture is denied by the system, the pane's reason reads "Aletheia doesn't have permission to capture the call audio. Open System Settings > Privacy & Security > Screen & System Audio Recording and turn it on for Aletheia."
  `surface: ui` · `evidence: Sources/App/Services/SystemAudioCapture.swift:10, Sources/App/Services/SessionRecorder.swift:328` · `qa: RECORD-05`
- **REC-014** When about 90 seconds of unpaused recording pass without any sound on the call track, and no other call-audio problem is showing, the session pane shows "No call audio detected. Only your microphone is being recorded." with advice to check the call plays through this Mac and that Aletheia is allowed under Screen & System Audio Recording.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:560, Sources/App/Services/SessionRecorder.swift:66` · `qa: RECORD-05`
- **REC-015** When call sound is heard at any point in a recording, the "No call audio detected" warning is not shown, so a patient who is quiet mid-session does not trigger it.
  `surface: ui` · `evidence: Sources/App/Services/SessionRecorder.swift:80` · `qa: RECORD-05`
- **REC-016** When recording is paused, the "No call audio detected" warning is hidden.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:560` · `qa: RECORD-05`
- **REC-017** When recording is paused, time spent paused does not count toward the 90 seconds of call-audio silence.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:517` · `qa: RECORD-05`
- **REC-018** When the app records call audio, its own audio output is excluded from the call-audio track.
  `surface: invariant` · `evidence: Sources/App/Services/SystemAudioCapture.swift:207` · `qa: RECORD-02`
- **REC-019** When Settings > "Show recording diagnostics" is on, the recording pane shows a "Call audio diagnostics" readout of permission and stream state that refreshes about once a second.
  `surface: ui` · `evidence: Sources/App/Views/CallAudioDebugView.swift, Sources/App/Views/SettingsView.swift:373, Sources/App/Views/SessionDetailView.swift:563` · `qa: SETTINGS-11`
- **REC-020** When the user presses Pause, the timer holds still, the chip changes to Paused and the pane says "Paused. Nothing is being recorded until you resume."
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:391, Sources/App/Views/SessionDetailView.swift:566, Sources/App/Services/SessionRecorder.swift:372` · `qa: RECORD-04`
- **REC-021** When the user presses Resume after pausing, recording continues in the same session and the paused span is not present in the audio.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:372, Sources/App/Services/MicRecorder.swift:144` · `qa: RECORD-14`
- **REC-022** When the user presses Stop Recording, the recording ends, the audio is saved with the session, and the session screen leaves the recording pane.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:1540, Sources/App/Services/SessionRecorder.swift:413` · `qa: RECORD-09`
- **REC-023** When the user stops a recording and "Transcribe automatically when a recording ends" is on (the default), transcription starts by itself.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:131, Sources/App/Views/SettingsView.swift:196, Sources/App/Services/AppSettings.swift:504` · `qa: RECORD-09`
- **REC-024** When the user stops a recording and "Transcribe automatically when a recording ends" is off, the session waits for the user to press Transcribe.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:131` · `qa: RECORD-09`
- **REC-025** When Aletheia is quit during a recording and the recording can be finalized within the quit's short wait, the audio is saved to the session.
  `surface: background` · `evidence: Sources/App/Services/Shutdown/AppLifecycle.swift:62, Sources/App/Services/SessionRecorder.swift:406, Sources/App/Services/Shutdown/ShutdownCoordinator.swift:95` · `qa: RECORD-10`
- **REC-026** When Aletheia is quit during a recording, transcription is not started at that moment.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:437` · `qa: RECORD-10`
- **REC-027** When Aletheia is quit during a recording and "Transcribe automatically when a recording ends" is on, the session is transcribed after the next launch.
  `surface: background` · `evidence: Sources/App/Services/Shutdown/AppLifecycle.swift:57, Sources/App/Services/Shutdown/AppLifecycle.swift:107` · `qa: RECORD-10`
- **REC-028** When finalizing a recording takes longer than the quit allows, the quit goes ahead and the staged audio is recovered into its session at the next launch.
  `surface: background` · `evidence: Sources/App/Services/Shutdown/ShutdownCoordinator.swift:95, Sources/App/Services/OrphanAudioSweep.swift:45` · `qa: RECORD-10`
- **REC-029** When a session is recording, the session pane shows a level bar labeled "Your microphone" and another labeled "Call audio", each with an accessibility label ending in "level" and a percent value.
  `surface: ui` · `evidence: Sources/App/Views/InputLevelMeter.swift:5` · `qa: RECORD-02`
- **REC-030** When the recording is paused, the session pane's level bars read zero and are dimmed to half strength.
  `surface: ui` · `evidence: Sources/App/Views/InputLevelMeter.swift:16, Sources/App/Views/SessionDetailView.swift:535, Sources/App/Services/SessionRecorder.swift:372` · `qa: RECORD-04`
- **REC-031** When an audio source stops delivering sound, its level bar returns to empty instead of freezing at the last reading.
  `surface: ui` · `evidence: Sources/App/Services/AudioLevel.swift:113-118` · `qa: RECORD-02`
- **REC-032** When the sound is very quiet, the level bar shows empty.
  `surface: ui` · `evidence: Sources/App/Services/AudioLevel.swift:16` · `qa: RECORD-02`
- **REC-033** When the sound gets louder the level bar rises quickly, and when it gets quieter the bar falls gradually.
  `surface: ui` · `evidence: Sources/App/Services/AudioLevel.swift:77` · `qa: RECORD-02`
- **REC-034** When a recording has run 90 minutes since it began (paused time counts), an alert titled "Still recording" appears over whatever screen is open with Keep Recording and Stop Now buttons.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift:119, Sources/App/Services/SessionRecorder.swift:482` · `qa: RECORD-08`
- **REC-035** When the "Still recording" alert is shown, its text reads "<patient name>'s session has been recording for over 90 minutes. Did you forget to end it?"
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift:122, Sources/App/Services/Notifications/SessionNotifications.swift:67` · `qa: RECORD-08`
- **REC-036** When a recording has run 90 minutes and notifications are allowed for Aletheia, a system notification titled "Still recording" says the session has been recording for over 90 minutes and asks "Did you forget to end it?"
  `surface: background` · `evidence: Sources/App/AletheiaApp.swift:106, Sources/App/Services/Notifications/SessionNotifications.swift:67, Sources/App/Services/Notifications/UserNotificationService.swift:13` · `qa: RECORD-08`
- **REC-037** When the 90-minute reminder is a notification and "Show patient names in notifications" is off (the default), the text says "A session" instead of naming the patient.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift:71, Sources/App/Services/AppSettings.swift:461` · `qa: RECORD-08`
- **REC-038** When the user presses Keep Recording on the 90-minute alert, the recording continues unchanged and the reminder does not appear again for that recording.
  `surface: ui` · `evidence: Sources/App/Services/SessionRecorder.swift:482, Sources/App/Views/RootView.swift:120` · `qa: RECORD-08`
- **REC-039** When the user presses Stop Now on the 90-minute alert, the recording stops and is saved.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift:121` · `qa: RECORD-08`
- **REC-040** When a recording runs past 90 minutes and nobody answers the reminder, the app never stops the recording by itself.
  `surface: invariant` · `evidence: Sources/App/Services/SessionRecorder.swift:482` · `qa: RECORD-08`
- **REC-041** While a recording is running, its audio is written to a private staging folder that only the current user can open, not to the patient's session folder.
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift:601, Sources/App/Services/Crypto/PrivateStaging.swift:65, Sources/App/Services/SessionRecorder.swift:242` · `qa: BUILD-11`
- **REC-042** When a recording stops and encryption is on, the staged audio is encrypted into the session folder and the plaintext staged copy is removed.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:444, Sources/App/Services/Crypto/FileProtector.swift:171` · `qa: ENCRYPT-05`
- **REC-043** When a recording stops and encryption is off, the staged audio is moved into the session folder.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:444, Sources/App/Services/Crypto/FileProtector.swift:177` · `qa: BUILD-11`
- **REC-044** When a recording cannot be encrypted on stop (for example the encrypted folder is locked), the audio stays in the private staging folder, never as plaintext in the session folder, and is added to the session, encrypted, the next time Aletheia opens.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:460, Sources/App/Services/OrphanAudioSweep.swift:45` · `qa: ENCRYPT-10`
- **REC-045** When a recording could not be encrypted on stop, automatic transcription does not start for it.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:437` · `qa: ENCRYPT-10`
- **REC-046** When the app is force-quit or crashes mid-recording, the audio captured up to that moment stays readable and is recovered into its session at the next launch.
  `surface: background` · `evidence: Sources/App/Services/AudioCrashSafety.swift, Sources/App/Services/MicFileWriter.swift, Sources/App/Services/MicRecorder.swift:165` · `qa: RECORD-10`
- **REC-047** When Aletheia launches and finds staged audio belonging to a known session, the audio is moved or encrypted into that session and the recovery appears in the activity log as "Recording recovered".
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:80, Sources/App/Services/AuditLog.swift:65` · `qa: RECORD-10`
- **REC-048** When Aletheia launches and finds staged audio for a session that is not in the current data folder, the audio is moved to a private set-aside folder and never deleted.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:62, Sources/App/Services/Crypto/PrivateStaging.swift` · `qa: RECORD-11`
- **REC-049** When Aletheia launches with encryption on and finds an older unencrypted recording in a session folder, the recording is encrypted in place.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:106` · `qa: ENCRYPT-05`
- **REC-050** When an older unencrypted recording is encrypted in place at launch, the activity log shows "Recording recovered" for that session.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:126` · `qa: ENCRYPT-05`
- **REC-051** When Aletheia launches, leftover decrypted temporary audio in the private scratch folder and in the shared temporary directory is deleted.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:135, Sources/App/Services/Crypto/PrivateStaging.swift:74` · `qa: BUILD-11`
- **REC-052** When the data folder is encrypted and locked at launch, the orphan-audio sweep does not run until it is unlocked, and then runs in the same launch.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:34, Sources/App/Services/Shutdown/AppLifecycle.swift:97` · `qa: BUILD-11`
- **REC-053** When a session is recovered by the launch sweep, has no transcript and "Transcribe automatically when a recording ends" is on, it is transcribed after the launch.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:88, Sources/App/Services/Shutdown/AppLifecycle.swift:107` · `qa: RECORD-10`
- **REC-054** When a call-audio stream fails during a recording while the microphone is still running, the pane shows "Only your microphone is being recorded." with the reason and the recording continues.
  `surface: ui` · `evidence: Sources/App/Services/SessionRecorder.swift:294, Sources/App/Views/SessionDetailView.swift:558` · `qa: RECORD-05`
- **REC-055** When the microphone input device changes during a recording, the recording continues into the same file; if restarting the input fails, no message appears on the recording screens or menu bar, and the failure shows only as "First failure" in Doctor's call-audio diagnostics.
  `surface: background` · `evidence: Sources/App/Services/MicRecorder.swift:94, Sources/App/Services/MicFileWriter.swift:36` · `qa: RECORD-02`
- **REC-056** When the microphone is recorded, it is captured without Apple voice processing, so the audio is not altered by echo cancellation.
  `surface: invariant` · `evidence: Sources/App/Services/MicRecorder.swift:140` · `qa: RECORD-02`
- **REC-057** When the app captures call audio, it records only audio from the Mac's output and stores no screen video or images.
  `surface: invariant` · `evidence: Sources/App/Services/SystemAudioCapture.swift:205, Sources/App/Services/SystemAudioCapture.swift:220` · `qa: BUILD-10`
- **REC-058** When the app captures call audio, it captures everything the Mac plays except Aletheia's own sound, once Screen Recording access is granted, so any call app or browser works without per-app setup.
  `surface: background` · `evidence: Sources/App/Services/SystemAudioCapture.swift:198` · `qa: RECORD-02`
- **REC-059** When recording, the app holds no network permission of its own.
  `surface: invariant` · `evidence: scripts/check-entitlements.sh, Sources/App/Resources/Aletheia.entitlements` · `qa: BUILD-01`
- **REC-060** When recording, no audio is sent off the Mac.
  `surface: invariant` · `evidence: docs/HIPAA-SAFEGUARDS.md:54, scripts/check-entitlements.sh` · `qa: BUILD-07`
- **REC-061** When the user opens the menu bar panel while the app is locked, it shows "Aletheia is locked" and an Unlock button instead of recording controls.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:44` · `qa: MENUBAR-09`
- **REC-062** When the menu bar panel is open, nothing is recording and at least one patient exists, it shows "Not recording", a Patient picker, a Start recording button and the note "Records a new session. Make sure your client has consented first."
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:225` · `qa: MENUBAR-02`
- **REC-063** When there are no patients, the menu bar panel says "Add a patient in the main window first." and offers no way to start a recording.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:234` · `qa: MENUBAR-07`
- **REC-064** When the disk is known to be unencrypted and the user presses Start recording in the menu bar panel, no session is created, nothing is recorded, and the panel shows "The disk holding your data folder isn't encrypted, so Aletheia can't add new patients, sessions or recordings yet." followed by how to turn on FileVault.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:281, Sources/App/Services/DiskEncryption.swift:47` · `qa: MENUBAR-08`
- **REC-065** When the disk is known to be unencrypted and the user presses Record Session, recording does not start and a "Turn on FileVault" alert appears.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:1521, Sources/App/Services/AppModel.swift:516, Sources/App/Views/RootView.swift:98` · `qa: RECORD-07`
- **REC-066** When the menu bar panel cannot create a session, it shows "Couldn't create a session. Check the data folder in Settings." and stays open.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:286` · `qa: MENUBAR-08`
- **REC-067** When a recording fails to start from the menu bar panel, the reason is shown under the Start recording button and the panel stays open.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:291` · `qa: MENUBAR-08`
- **REC-068** When a recording fails to start from the session screen, a "Something went wrong" alert shows the reason.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:364, Sources/App/Views/SessionDetailView.swift:1526` · `qa: RECORD-06`
- **REC-069** When a recording is running, the menu bar panel shows a Recording chip, the patient's initials (the full name only when "Show patient names in notifications and the menu bar" is on), an HH:MM:SS timer, Mic and Call level bars, a Pause button and a Stop and save button.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:130` · `qa: MENUBAR-04`
- **REC-070** When a recording is paused, the menu bar panel shows a Paused chip, a muted timer, the note "Nothing is being captured. Resume to continue the same session." and a Resume button, and hides the level bars.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:141` · `qa: MENUBAR-05`
- **REC-071** When the user presses Stop and save in the menu bar panel, the recording ends and is saved, and the panel returns to Not recording.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:160` · `qa: MENUBAR-06`
- **REC-072** When the menu bar panel is open and the app is unlocked, it offers Open Aletheia and Quit Aletheia and shows the AI engine status line; while locked it shows only "Aletheia is locked" and Unlock.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:76` · `qa: MENUBAR-02`
- **REC-073** When a recording is running, the menu bar panel offers Show this session, which brings the main window forward on that patient.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:68` · `qa: MENUBAR-04`
- **REC-074** When a transcription is running, the menu bar panel shows its status line with a spinner.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:84` · `qa: MENUBAR-06`
- **REC-075** When a recording is paused, the menu bar timer holds still rather than counting wall-clock time.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift:195, Sources/App/Services/SessionRecorder.swift:593` · `qa: MENUBAR-05`
- **REC-076** When a new recording starts for a session that still has an earlier unsealed recording in staging, the earlier recording is put into the session first and is not overwritten.
  `surface: background` · `evidence: Sources/App/Services/SessionRecorder.swift:246` · `qa: RECORD-09`
- **REC-077** When the user first presses Record, the system asks for microphone permission.
  `surface: ui` · `evidence: Sources/App/Services/SessionRecorder.swift:280, Sources/App/Services/MicRecorder.swift:59` · `qa: RECORD-01`

## Set-aside recordings (SAR)

- **SAR-001** When a recording cannot be matched to any session, it is set aside in a private folder on the Mac rather than deleted.
  `surface: background` · `evidence: Sources/App/Services/SetAsideRecordings.swift, Sources/App/Services/OrphanAudioSweep.swift:62` · `qa: RECORD-11`
- **SAR-002** When set-aside recordings exist, the main window shows a warning strip reading "N recordings couldn't be matched to a session and are set aside on this Mac, unencrypted, until you recover or delete them." (singular for one), with a "Review in Settings…" button, and never names a patient.
  `surface: ui` · `evidence: Sources/App/Services/SetAsideRecordings.swift:47-50, Sources/App/Views/DatabaseUnavailableBanner.swift:227, Sources/App/Views/RootView.swift:222-225` · `qa: RECORD-11`
- **SAR-003** When the user opens Settings > Set-aside recordings, each item offers "Recover Into…", "Show in Finder" and "Delete…", and the pane has "Try Again" and "Choose Data Folder…" buttons.
  `surface: ui` · `evidence: Sources/App/Views/Settings/SetAsideRecordingsPane.swift:29-31, Sources/App/Views/Settings/SetAsideRecordingsPane.swift:44-46` · `qa: RECORD-12`
- **SAR-004** When the user chooses Recover Into, only sessions without a recording are offered, so no existing recording is overwritten.
  `surface: ui` · `evidence: Sources/App/Views/Settings/SetAsideRecordingsPane.swift:117, Sources/App/Services/OrphanAudioSweep.swift:224` · `qa: RECORD-12`
- **SAR-005** When the user recovers a set-aside recording into a session, it is added to that session, encrypted if encryption is on, and removed from the set-aside list.
  `surface: ui` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:224, Sources/App/Views/Settings/SetAsideRecordingsPane.swift:155` · `qa: RECORD-12`
- **SAR-006** When a set-aside recording is recovered into a session, the activity log shows "Recording recovered".
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:236` · `qa: RECORD-12`
- **SAR-007** When the user chooses Delete on a set-aside recording, a "Delete this recording?" confirmation says it is removed from this Mac for good, and after the user confirms, the audio is removed and the activity log shows "Record deleted".
  `surface: ui` · `evidence: Sources/App/Views/Settings/SetAsideRecordingsPane.swift:62, Sources/App/Services/SetAsideRecordings.swift:71` · `qa: RECORD-13`
- **SAR-008** When the user presses Try Again, the app attempts again to match set-aside recordings to sessions and reports "Recovered N of M into their sessions." or "Their sessions still can't be found in this data folder."
  `surface: ui` · `evidence: Sources/App/Views/Settings/SetAsideRecordingsPane.swift:85, Sources/App/Services/OrphanAudioSweep.swift:180` · `qa: RECORD-13`
- **SAR-009** When Aletheia launches, it tries again to place set-aside recordings, so recovery is never a one-time attempt.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:55, Sources/App/Services/Shutdown/AppLifecycle.swift:98` · `qa: RECORD-13`
- **SAR-010** When the user returns to the app, the set-aside list refreshes without a restart.
  `surface: ui` · `evidence: Sources/App/Services/SetAsideRecordings.swift:35` · `qa: RECORD-13`
- **SAR-011** When no recordings are set aside, the warning strip is not shown and the Set-aside recordings pane is missing from the Settings sidebar.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift:222, Sources/App/Views/Settings/SettingsComponents.swift:39` · `qa: RECORD-13`
- **SAR-012** When a set-aside recording is never recovered, the audio is never deleted automatically.
  `surface: invariant` · `evidence: Sources/App/Services/SetAsideRecordings.swift, Sources/App/Services/OrphanAudioSweep.swift:62` · `qa: RECORD-13`
- **SAR-013** When a retry finds the matching session already has a recording, the set-aside recording is left set aside instead of replacing it.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:80, Sources/App/Services/OrphanAudioSweep.swift:154` · `qa: RECORD-12`
- **SAR-014** When the user tries to recover into a session that already has a recording or one being saved, the sheet shows "That session already has a recording, or one is being saved. Choose another session."
  `surface: ui` · `evidence: Sources/App/Services/OrphanAudioSweep.swift:200` · `qa: RECORD-12`
- **SAR-015** When a set-aside recording is listed, it shows "Recorded" with its date and its size, not a patient name.
  `surface: ui` · `evidence: Sources/App/Views/Settings/SetAsideRecordingsPane.swift:75` · `qa: RECORD-12`

## Voice input (VOI)

- **VOI-001** When the user presses and holds the microphone button in the Ask box, dictation starts and spoken words appear in the draft as they are recognized.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:82, Sources/App/Services/VoiceInput.swift:111` · `qa: CHAT-07`
- **VOI-002** When the user hovers over the dictation button, the tooltip reads "Press and hold to record".
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:10` · `qa: CHAT-07`
- **VOI-003** When the user releases the button, dictation stops and the final recognized text is still added to the draft.
  `surface: ui` · `evidence: Sources/App/Services/VoiceInput.swift:123` · `qa: CHAT-07`
- **VOI-004** When the user presses Esc during dictation, dictation stops and the draft returns to what it was before.
  `surface: ui` · `evidence: Sources/App/Services/VoiceInput.swift:131, Sources/App/Views/VoiceMicControl.swift:103` · `qa: CHAT-07`
- **VOI-005** When the draft already has text, dictated words are added after it with a space.
  `surface: ui` · `evidence: Sources/App/Services/VoiceInput.swift:47` · `qa: CHAT-07`
- **VOI-006** When the user presses the dictation button before permissions have been decided, the app asks for microphone and speech-recognition permission and does not start recording on that press.
  `surface: ui` · `evidence: Sources/App/Services/VoiceInput.swift:111, Sources/App/Services/VoiceInput.swift:226` · `qa: CHAT-07`
- **VOI-007** When speech or microphone permission has been denied, the dictation button is hidden.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:42, Sources/App/Services/VoiceInput.swift:25` · `qa: CHAT-07`
- **VOI-008** When on-device speech recognition is not supported on the Mac, the dictation button is hidden.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:42, Sources/App/Services/VoiceInput.swift:205` · `qa: CHAT-07`
- **VOI-009** When a reply is being generated, the dictation button is hidden and any dictation in progress ends.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:61, Sources/App/Views/ChatPaneView.swift:277` · `qa: CHAT-07`
- **VOI-010** When any session is being recorded, the dictation button is hidden so it does not compete for the microphone.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:62, Sources/App/Views/SessionDetailView.swift:1444, Sources/App/Views/PatientChatView.swift:94` · `qa: CHAT-07`
- **VOI-011** When a session recording starts during dictation, dictation ends and stops writing into the draft, leaving the text so far.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:62, Sources/App/Services/VoiceInput.swift:141` · `qa: CHAT-07`
- **VOI-012** When the user sends the message during dictation, dictation ends and nothing more is added to the draft.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:60, Sources/App/Services/VoiceInput.swift:141` · `qa: CHAT-07`
- **VOI-013** When the user leaves the Ask box during dictation, dictation ends.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:63` · `qa: CHAT-07`
- **VOI-014** When dictating, speech recognition runs only on the Mac, and there is no fallback to a server.
  `surface: invariant` · `evidence: Sources/App/Services/VoiceInput.swift:196` · `qa: CHAT-07`
- **VOI-015** When the Ask box is open in a session or in a patient's chat, the dictation button is available in both.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:280, Sources/App/Views/SessionDetailView.swift:1432, Sources/App/Views/PatientChatView.swift:78` · `qa: CHAT-07`
- **VOI-016** When the user holds the dictation button, the button changes to a filled microphone in the recording color.
  `surface: ui` · `evidence: Sources/App/Views/VoiceMicControl.swift:115` · `qa: CHAT-07`
- **VOI-017** When speech recognition ends with an error, dictation stops quietly and the text recognized so far stays in the draft.
  `surface: ui` · `evidence: Sources/App/Services/VoiceInput.swift:262` · `qa: CHAT-07`

## Transcription (TRN)

- **TRN-001** When Settings > AI shows Speech recognition, it offers four speech models (Base, Small, Medium, Large v3), a Recommended-for-your-Mac hint, and a chip reading Installed, Downloading or Not downloaded.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:425, Sources/App/Services/AppSettings.swift:6` · `qa: SETTINGS-05`
- **TRN-002** When the selected speech model is not downloaded, Settings shows its approximate size and a Download button; when it is installed, a Re-download button is shown instead.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:450` · `qa: SETTINGS-05`
- **TRN-003** When the user presses Download for a speech model, a progress bar with a percentage is shown while it downloads, and it is fetched only through the sandboxed network helper.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:450, Sources/App/Services/WhisperModelDownloader.swift` · `qa: SETTINGS-05`
- **TRN-004** When a downloaded speech model's file size does not match the expected size at the start of a transcription, no transcript is produced and the user is told "The speech-to-text model file is damaged or incomplete. Open Settings and download it again."
  `surface: ui` · `evidence: Sources/App/Services/WhisperTranscriber.swift:50-54, Sources/App/Services/WhisperModelDownloader.swift:73` · `qa: TRANSCRIBE-01`
- **TRN-005** When the speech model has not been downloaded, pressing Transcribe does not produce a transcript and the user is told "The speech-to-text model hasn't been downloaded yet. Open Settings and download it first."
  `surface: ui` · `evidence: Sources/App/Services/WhisperTranscriber.swift:6-17, Sources/App/Views/SessionDetailView.swift:1588` · `qa: TRANSCRIBE-01`
- **TRN-006** When the user presses Transcribe on a session that has a recording, a progress band appears above the tabs showing the stage and a percentage.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:286, Sources/App/Views/TranscriptionProgressView.swift` · `qa: TRANSCRIBE-02`
- **TRN-007** When transcription runs, the stages shown are Preparing audio, Transcribing mic, Transcribing call audio and Saving, in that order, with the mic and call stages shown only for tracks whose recording file exists.
  `surface: ui` · `evidence: Sources/App/Services/WhisperTranscriber.swift:58-62, Sources/App/Services/TranscriptionProgress.swift:5-24` · `qa: TRANSCRIBE-02`
- **TRN-008** When transcription runs, the percentage never moves backward.
  `surface: invariant` · `evidence: Sources/App/Services/TranscriptionProgress.swift` · `qa: TRANSCRIBE-02`
- **TRN-009** When the speech model has been transcribing for at least 10 seconds and has completed more than 1 percent of the work since it started, the band adds a time estimate such as "about N min left" or "less than a minute left".
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionProgress.swift:46-60, Sources/App/Views/TranscriptionProgressView.swift` · `qa: TRANSCRIBE-02`
- **TRN-010** When another session is already being transcribed, pressing Transcribe queues this one, shows a "Waiting to transcribe" band with a Cancel button, and starts it when the earlier one finishes.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift, Sources/App/Views/TranscriptionProgressView.swift:1-35` · `qa: TRANSCRIBE-03`
- **TRN-011** When several sessions are queued, they run one at a time in the order they were queued.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift` · `qa: TRANSCRIBE-03`
- **TRN-012** When the user cancels a transcription while it is preparing or transcribing, no new transcript is written and any partial transcript is discarded.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:212-227, Sources/App/Views/SessionDetailView.swift:1588` · `qa: TRANSCRIBE-05`
- **TRN-013** When a transcription is running, the Mac is kept from going to idle sleep until it finishes.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:200` · `qa: TRANSCRIBE-04`
- **TRN-014** When the user leaves the session screen during a transcription, it keeps running and the menu bar panel shows "Transcribing…" with a percentage.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift, Sources/App/Views/RecordingMenuBar.swift:85` · `qa: TRANSCRIBE-04`
- **TRN-015** When the app is locked during a transcription, the transcription keeps running.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift:156,282, Sources/App/Views/HoverTip.swift:43` · `qa: TRANSCRIBE-04`
- **TRN-016** When Aletheia is quit while a transcription is running or waiting, that session is recorded as interrupted in a hidden file in the data folder and is transcribed again at the next launch once the sessions can be read.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:246, Sources/App/Services/Shutdown/ShutdownCoordinator.swift:20-70` · `qa: TRANSCRIBE-06`
- **TRN-017** When a transcription finishes, a notification says it is ready, naming the patient only if notification names are enabled.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift, Sources/App/Services/Notifications/SessionNotifications.swift:19` · `qa: NOTIFY-02`
- **TRN-018** When a transcription fails, an alert titled "Something went wrong" shows the reason on the session screen and a "Transcription needs attention" notification tells the user.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:1588, Sources/App/Services/TranscriptionCoordinator.swift:92-106` · `qa: TRANSCRIBE-13`
- **TRN-019** When a transcription finishes successfully, the transcript is saved only if it is complete, never as a partial file.
  `surface: invariant` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift` · `qa: TRANSCRIBE-08`
- **TRN-020** When a transcription finishes with speech detected, the recording is deleted by default and only the transcript is kept.
  `surface: background` · `evidence: Sources/App/Services/AudioRetentionPolicy.swift, Sources/App/Services/TranscriptionCoordinator.swift, README.md` · `qa: TRANSCRIBE-08`
- **TRN-021** When Settings > Keep raw audio after transcription is on and encryption is on, the recording is kept after a successful transcription.
  `surface: background` · `evidence: Sources/App/Services/AudioRetentionPolicy.swift, Sources/App/Views/SettingsView.swift:187` · `qa: TRANSCRIBE-12`
- **TRN-022** When encryption is off, the Keep raw audio setting is disabled so it cannot be turned on.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:187-194, Sources/App/Views/Settings/SettingsComponents.swift:75` · `qa: TRANSCRIBE-12`
- **TRN-023** When a recording cannot be deleted after a successful transcription, the transcript is kept, the Transcript tab shows "The transcript is saved, but the recording couldn't be deleted and is still in your data folder. Delete it from the session folder to remove it." and a "Recording still on disk" notification is posted.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:250-260, Sources/App/Services/Notifications/SessionNotifications.swift:51` · `qa: TRANSCRIBE-09`
- **TRN-024** When a transcription produces no speech or only whitespace, the recording is kept regardless of the retention setting.
  `surface: invariant` · `evidence: Sources/App/Services/AudioRetentionPolicy.swift:58, Sources/App/Services/TranscriptionCoordinator.swift:238` · `qa: TRANSCRIBE-09`
- **TRN-025** When a transcription produces no speech, the Transcript tab shows a dismissible notice: "No speech was detected, so the recording was kept. Tap Transcribe to try again, or delete the recording files (mic.caf / call.caf in this session's folder) if you don't need them.", followed by " At-rest encryption is off, so the kept recording is not encrypted." when encryption is off.
  `surface: ui` · `evidence: Sources/App/Services/AudioRetentionPolicy.swift:68-75, Sources/App/Views/SessionDetailView.swift:712-726` · `qa: TRANSCRIBE-09`
- **TRN-026** When a no-speech recording is kept while encryption is off, the notice also says "At-rest encryption is off, so the kept recording is not encrypted."
  `surface: ui` · `evidence: Sources/App/Services/AudioRetentionPolicy.swift:68-75` · `qa: TRANSCRIBE-09`
- **TRN-027** When a track is silent throughout, it is skipped rather than transcribed, to avoid invented text.
  `surface: background` · `evidence: Sources/App/Services/WhisperTranscriber.swift:110, Sources/App/Services/AudioResampler.swift:106` · `qa: TRANSCRIBE-09`
- **TRN-028** When transcribing, the microphone track is labeled "You" and the call track "Call audio" in the saved text, and lines from both are merged in time order.
  `surface: background` · `evidence: Sources/App/Services/WhisperTranscriber.swift:62-68, Sources/App/Services/TranscriptFormatter.swift` · `qa: TRANSCRIBE-07`
- **TRN-029** When the transcript is shown, "Call audio" is displayed as the patient's first name, and stays "Call audio" if the patient's name is empty.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptTextView.swift:401, Sources/App/Services/TranscriptStyler.swift:92, Sources/App/Services/Prompts.swift:78` · `qa: TRANSCRIBE-07`
- **TRN-030** When transcript text is copied from the transcript view, the speaker is named by the patient's first name and no overlap marks are included.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptTextView.swift:169-176, Sources/App/Services/TranscriptStyler.swift` · `qa: TRANSCRIBE-07`
- **TRN-031** When transcript lines are written, each begins with a [MM:SS] time stamp, and time past 59 minutes keeps counting minutes, such as [75:12].
  `surface: ui` · `evidence: Sources/App/Services/TranscriptFormatter.swift:92-96, Sources/App/Services/TranscriptTimeline.swift` · `qa: TRANSCRIBE-07`
- **TRN-032** When a line overlaps other-speaker speech for at least 1 second and at least 30 percent of its length, the saved text marks its speaker label "(overlapping)".
  `surface: invariant` · `evidence: Sources/App/Services/TranscriptFormatter.swift:38-70` · `qa: TRANSCRIBE-07`
- **TRN-033** When a microphone line mostly repeats call-audio words spoken within 5 seconds, it is dropped as speaker leakage, but lines shorter than 5 words are never dropped.
  `surface: background` · `evidence: Sources/App/Services/SpeakerLeakageFilter.swift` · `qa: TRANSCRIBE-07`
- **TRN-034** When a transcribed segment consists only of non-speech tags such as [BLANK_AUDIO], (static) or *sigh*, or only of punctuation, it is removed from the transcript.
  `surface: background` · `evidence: Sources/App/Services/TranscriptCleaner.swift:77-98` · `qa: TRANSCRIBE-07`
- **TRN-035** When the same speaker has consecutive lines within 3 seconds and no other-speaker line between them, they are merged into one line no longer than 45 seconds.
  `surface: background` · `evidence: Sources/App/Services/TranscriptCleaner.swift:159-186` · `qa: TRANSCRIBE-07`
- **TRN-036** When transcribing, voice-activity detection skips non-speech stretches using the bundled detector with no download.
  `surface: background` · `evidence: Sources/WhisperEngine/WhisperEngine.swift:116-125` · `qa: BUILD-05`
- **TRN-037** When transcribing, the language is English only, even if the multilingual Large v3 model is chosen.
  `surface: invariant` · `evidence: Sources/WhisperEngine/WhisperEngine.swift:86, Sources/App/Services/WhisperTranscriber.swift:131, Sources/App/Services/AppSettings.swift:17` · `qa: TRANSCRIBE-07`
- **TRN-038** When the transcript view is shown, time stamps are muted and speaker labels are colored, microphone in green and call in amber.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptTextView.swift:228-248, Sources/App/Services/TranscriptStyler.swift` · `qa: TRANSCRIBE-07`
- **TRN-039** When the user types in the transcript, edits are plain text with no auto-correct, smart quotes or pasted styling.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptTextView.swift:95-109` · `qa: TRANSCRIBE-10`
- **TRN-040** When the user edits the transcript, an edit bar appears with Save and Discard and the note "Edits to the transcript are not saved yet"; it is hidden when there are no edits.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptEditBar.swift, Sources/App/Views/SessionDetailView.swift:744` · `qa: TRANSCRIBE-10`
- **TRN-041** When the user presses Save in the edit bar, the edited text becomes the saved transcript.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:1061-1076` · `qa: TRANSCRIBE-10`
- **TRN-042** When the user presses Discard, a confirmation asks "Discard your unsaved edits?" and confirming restores the last saved transcript.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:812-816,1074` · `qa: TRANSCRIBE-11`
- **TRN-043** When the user tries to switch sessions with unsaved transcript edits, the app asks "Save your transcript edits?" with Save, Discard Edits and Cancel before leaving.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift:171-185, 206-215, Sources/App/Views/UnsavedTranscriptGuard.swift` · `qa: TRANSCRIBE-11`
- **TRN-044** When the transcript view goes away by a route that cannot ask, the unsaved edits are held in memory and restored, still unsaved, when the session is opened again.
  `surface: ui` · `evidence: Sources/App/Views/UnsavedTranscriptGuard.swift, Sources/App/Views/SessionDetailView.swift` · `qa: TRANSCRIBE-11`
- **TRN-045** When a transcription completes for a session with unsaved edits, the new transcript replaces the edits.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:1588-1612` · `qa: TRANSCRIBE-11`
- **TRN-046** When the saved transcript cannot be read, editing is turned off and a message explains it, so the file is not overwritten.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:738, 1615-1626` · `qa: TRANSCRIBE-10`
- **TRN-047** When a session has no transcript yet, the pane says "No transcript yet" and prompts the user to record or to transcribe, as appropriate.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:587-603` · `qa: TRANSCRIBE-01`
- **TRN-048** When the user selects text in a saved transcript, a Comment button appears, and it is hidden when there are unsaved edits or no selection.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:872` · `qa: COMMENT-01`
- **TRN-049** When a transcript has comments, their passages are highlighted, and clicking a highlight opens its comment.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptHighlighter.swift, Sources/App/Views/TranscriptTextView.swift` · `qa: COMMENT-03`
- **TRN-050** When the user clicks a comment card, the transcript scrolls to its passage and flashes it.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:970, Sources/App/Views/TranscriptTextView.swift:476` · `qa: COMMENT-04`
- **TRN-051** When a comment's quoted passage can no longer be found in the transcript, the comment card says "Original passage not found" and is not deleted.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift:129, Sources/App/Services/TranscriptHighlighter.swift` · `qa: COMMENT-07`
- **TRN-052** When a transcript has no comments, it fills the full width; when it has comments, they sit beside it with the transcript taking about two thirds.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptSplit.swift, Sources/App/Views/TranscriptSplitView.swift` · `qa: COMMENT-01`
- **TRN-053** When the user drags the divider, each side keeps a minimum width, and dragging far enough folds a side into a narrow arrow strip that can be clicked to reopen it.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptSplit.swift, Sources/App/Views/TranscriptSplitView.swift` · `qa: COMMENT-05`
- **TRN-054** When comments are folded away and the user clicks a highlight, the comments reopen if there is room.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptSplitView.swift:59, Sources/App/Services/TranscriptSplit.swift:43-49` · `qa: COMMENT-05`
- **TRN-055** When a saved transcript has any time stamp after 0:00, the session header shows the session length taken from the last time stamp next to the start time.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:404-409, Sources/App/Services/TranscriptTimeline.swift` · `qa: TRANSCRIBE-07`
- **TRN-056** When Transcribe is pressed on a session whose recording was kept and that already has a transcript, the old transcript is replaced without asking for confirmation.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:476-480, docs/DESIGN-DECISIONS.md:140` · `qa: TRANSCRIBE-08`
- **TRN-057** When this session is recording, the Transcribe button is disabled with the tooltip "Stop the recording first".
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionProgress.swift:150-166, Sources/App/Views/SessionDetailView.swift:476-486` · `qa: TRANSCRIBE-03`
- **TRN-058** When the transcript is read aloud by VoiceOver, the call speaker is announced by the patient's first name and overlap marks are not read.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptTextView.swift:179-190` · `qa: TRANSCRIBE-07`
- **TRN-059** When a transcript is sent to the AI assistant, speakers are given as short codes and the assistant is told to write only "You" and the patient's first name.
  `surface: background` · `evidence: Sources/App/Services/TranscriptCompactor.swift, Sources/App/Services/Prompts.swift:92-112` · `qa: NOTE-14`
- **TRN-060** When a transcript is prepared for the assistant, the standalone filler words um, uh, erm and hmm are dropped.
  `surface: background` · `evidence: Sources/App/Services/TranscriptCompactor.swift:107-150` · `qa: NOTE-14`
- **TRN-061** When transcript text is handled, no audio or transcript content leaves the Mac.
  `surface: invariant` · `evidence: Sources/App/Resources/Aletheia.entitlements:27, README.md` · `qa: BUILD-07`
- **TRN-062** When a downloaded speech model's checksum does not match its pinned value, the download is discarded, any model already installed is left as it was, and the user is told "The downloaded model failed its integrity check and was discarded. Please try downloading it again."
  `surface: ui` · `evidence: Sources/App/Services/NetworkHelper/ModelFileInstaller.swift:10-16, Sources/App/Services/WhisperModelDownloader.swift:12-14` · `qa: SETTINGS-05`
- **TRN-063** When the user cancels a transcription, the recording files are kept.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:212-227, Sources/App/Views/TranscriptionProgressView.swift:100` · `qa: TRANSCRIBE-05`
- **TRN-064** When a transcription is cancelled or fails, the temporary decrypted copies of the recordings are removed.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:207-217` · `qa: TRANSCRIBE-05`
- **TRN-065** When encryption is off and Keep raw audio was left on from earlier, a successful transcription with speech still deletes the recording.
  `surface: background` · `evidence: Sources/App/Services/AudioRetentionPolicy.swift:44-60, Sources/App/Services/TranscriptionCoordinator.swift:225-244` · `qa: TRANSCRIBE-16`
- **TRN-066** When a transcription produces no speech, an existing saved transcript for the session is not overwritten.
  `surface: invariant` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:232-243` · `qa: TRANSCRIBE-17`
- **TRN-067** When transcript text is exported for a session or a patient's records, or shown in a search snippet, the speaker is named by the patient's first name and no overlap marks are included.
  `surface: ui` · `evidence: Sources/App/Services/MarkdownExporter.swift:22, Sources/App/Services/PatientArchive.swift:66, Sources/App/Services/Search/GlobalSearchEngine.swift:238` · `qa: TRANSCRIBE-07`
- **TRN-068** When the transcript is shown on screen, the "(overlapping)" mark is hidden.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptTextView.swift:245, Sources/App/Services/TranscriptStyler.swift:15-20` · `qa: TRANSCRIBE-07`
- **TRN-069** When a later line from the same speaker opens with a hyphen turn marker, it stays a separate line instead of being merged into the previous one.
  `surface: background` · `evidence: Sources/App/Services/TranscriptCleaner.swift:159-186,200-205` · `qa: TRANSCRIBE-07`
- **TRN-070** When saving edited transcript text fails, the edits stay on screen and an alert says "Couldn't save the transcript. Your edits are still here and nothing was lost."
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:1061-1070` · `qa: TRANSCRIBE-10`
- **TRN-071** When a drafted note is produced from a transcript, any leaked speaker codes at the start of lines or before speech verbs are replaced with "You" or the patient's first name ("the client" if unknown).
  `surface: background` · `evidence: Sources/App/Services/SpeakerCodes.swift, Sources/App/Views/SessionDetailView.swift:1738` · `qa: NOTE-04`
- **TRN-072** When a transcript is prepared for the assistant, a short sentence repeated five or more times in a row is collapsed to one copy with a repeat count.
  `surface: background` · `evidence: Sources/App/Services/TranscriptCompactor.swift:152-190` · `qa: NOTE-14`
- **TRN-073** When a session has both recordings, "Preparing audio" is shown again before the call track is transcribed, so the stage label can go back to Preparing audio while the percentage keeps rising.
  `surface: ui` · `evidence: Sources/App/Services/WhisperTranscriber.swift:104-110, Sources/App/Services/TranscriptionProgress.swift:16` · `qa: TRANSCRIBE-02`
- **TRN-074** When the user cancels a running transcription, the band reads "Cancelling… finishing the current step" and the Cancel button is unavailable once the Saving stage has begun.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptionProgressView.swift:58-60,100, Sources/App/Services/TranscriptionProgress.swift:186-196` · `qa: TRANSCRIBE-05`
- **TRN-075** When the user cancels a session that is waiting in the queue, it leaves the queue, the running transcription is not affected and the recordings are kept.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:146, Sources/App/Views/TranscriptionProgressView.swift:3-31` · `qa: TRANSCRIBE-05`
- **TRN-076** When the auto-transcribe setting is on (the default) and a recording is saved successfully, ending it starts transcription of that session, or queues it behind one already running.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:131-137, Sources/App/Views/SettingsView.swift:195` · `qa: RECORD-09`
- **TRN-077** When the finished transcript cannot be saved, the transcription is reported as failed and the recordings are not deleted.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:245-249` · `qa: TRANSCRIBE-14`
- **TRN-078** When the app is locked during a transcription, the folder key is dropped once that transcription finishes.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift:156,282-300` · `qa: TRANSCRIBE-04`
- **TRN-079** When a transcription interrupted by a quit is picked up at the next launch, it runs only if the session's recording still exists and is dropped if the patient or session is gone.
  `surface: background` · `evidence: Sources/App/Services/Shutdown/ShutdownCoordinator.swift:183-215` · `qa: TRANSCRIBE-06`
- **TRN-080** When the app quits with unsaved transcript edits held in memory, they are lost and the saved transcript is what reopens.
  `surface: invariant` · `evidence: Sources/App/Views/UnsavedTranscriptGuard.swift:40-61` · `qa: TRANSCRIBE-11`
- **TRN-081** When the user presses ⌘S with unsaved transcript edits, the edits are saved.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:755-757, Sources/App/Services/ShortcutCatalog.swift:19` · `qa: TRANSCRIBE-10`
- **TRN-082** When a no-speech or recording-kept notice is showing on the Transcript tab, it has a Dismiss button and is cleared when Transcribe is pressed again.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:477-480,707-722` · `qa: TRANSCRIBE-09`
- **TRN-083** When a transcription finds no speech, a "Transcription needs attention" notification tells the user.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:92-102, Sources/App/Services/Notifications/SessionNotifications.swift:41` · `qa: NOTIFY-03`
- **TRN-084** When only one of the two recording files exists, only that track is transcribed and the percentage still runs from 0 to 100.
  `surface: background` · `evidence: Sources/App/Services/WhisperTranscriber.swift:57-76, Sources/App/Services/TranscriptionProgress.swift:46-52` · `qa: TRANSCRIBE-02`
- **TRN-085** When a transcription is running, the background search-index sweep waits.
  `surface: background` · `evidence: Sources/App/Views/RootView.swift:278-296` · `qa: TRANSCRIBE-04`
- **TRN-086** When a transcription is running, the progress band's title reads "Transcribing <session date and time> · Whisper <model name>" such as "Whisper base.en".
  `surface: ui` · `evidence: Sources/App/Views/TranscriptionProgressView.swift:48-55, Sources/App/Services/TranscriptionCoordinator.swift:86` · `qa: TRANSCRIBE-02`
- **TRN-087** When a session has no recording file and is not being transcribed, no Transcribe button is shown.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionProgress.swift:134-136, Sources/App/Views/SessionDetailView.swift:476` · `qa: TRANSCRIBE-01`
- **TRN-088** When another session is recording, the Transcribe button is disabled with the tooltip "Another session is recording. Stop it first".
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionProgress.swift:150-166, Sources/App/Views/SessionDetailView.swift:1575-1582` · `qa: TRANSCRIBE-03`
- **TRN-089** When this session is being transcribed or is waiting in the queue, its Transcribe button is disabled with the tooltip "This session is being transcribed" or "Waiting for another transcription to finish".
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionProgress.swift:150-166` · `qa: TRANSCRIBE-03`
- **TRN-090** When encryption is on and a transcription finishes, the saved transcript is stored sealed, so its text cannot be read from the data folder without the passphrase.
  `surface: invariant` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, docs/ENCRYPTION.md` · `qa: TRANSCRIBE-15`
- **TRN-091** When a transcription is aborted, the recording is kept, the partial transcript is discarded, and the session shows a warning icon until it is transcribed or deleted.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift:212-227, Sources/App/Views/SessionDetailView.swift:1588` · `qa: TRANSCRIBE-05`
- **TRN-092** When a successful transcription deletes a raw audio recording for the first time, a one-time notice tells the user it was deleted after transcription, and the notice is not shown again.
  `surface: ui` · `evidence: Sources/App/Services/AudioRetentionPolicy.swift:44-60` · `qa: TRANSCRIBE-18`

## Encryption at rest (ENC)

- **ENC-001** When the user turns on encryption from Settings in a developer build, a three-step setup asks for a passphrase, shows a 24-word recovery key, and finishes with an "Encrypt my data" button.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/RecoveryKeyDocument.swift, Sources/App/Services/Crypto/AtRestEncryptionFeatureModule.swift` · `qa: ENCRYPT-02`
- **ENC-002** When the user types a passphrase shorter than 8 characters, the strength meter shows "Weak".
  `surface: ui` · `evidence: Sources/App/Services/Crypto/PassphraseStrength.swift` · `qa: ENCRYPT-02`
- **ENC-003** When the user enters a passphrase, a strength rating is shown that discounts repeated characters.
  `surface: ui` · `evidence: Sources/App/Services/Crypto/PassphraseStrength.swift` · `qa: ENCRYPT-02`
- **ENC-004** When encryption is on, patient records, transcripts, summaries, chats, notes, comments and recordings in the data folder are stored sealed rather than as plain text or audio; folder names, `session.json`, the database structure, the search index while unlocked, and set-aside or still-staging recordings are not sealed.
  `surface: invariant` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, Sources/App/Services/Crypto/DataMigrator.swift, docs/ENCRYPTION.md` · `qa: ENCRYPT-05`
- **ENC-005** When the user forgets the passphrase but has the recovery key, choosing "Use recovery key…" and entering the words unlocks the folder.
  `surface: ui` · `evidence: Sources/App/Views/FolderUnlockView.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: ENCRYPT-07`
- **ENC-006** When the user has neither the passphrase nor the recovery key and this Mac has not remembered the key, the encrypted records cannot be opened.
  `surface: invariant` · `evidence: Sources/App/Services/Crypto/Keystore.swift, Sources/App/Services/Crypto/RecoveryKeyDocument.swift` · `qa: ENCRYPT-07`
- **ENC-007** When the user opens an encrypted data folder that is not remembered on this Mac, a screen titled "This data folder is encrypted" asks for the passphrase before any patient is shown.
  `surface: ui` · `evidence: Sources/App/Views/FolderUnlockView.swift, Sources/App/Views/RootView.swift` · `qa: ENCRYPT-06`
- **ENC-008** When the user turns on "Unlock automatically on this Mac" in Settings, later launches unlock without a passphrase prompt, and turning it off makes the Mac forget the key.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/DeviceKeyStore.swift` · `qa: ENCRYPT-06`
- **ENC-009** When passphrase or recovery-key attempts fail, the first 3 failures are free and later ones make the user wait, starting at 2 seconds, doubling each time, up to 15 minutes.
  `surface: ui` · `evidence: Sources/App/Services/Crypto/UnlockThrottle.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: ENCRYPT-07`
- **ENC-010** When Aletheia must write a temporary decrypted copy of a file, it is placed in a private folder readable only by the user and not in a shared temporary location.
  `surface: background` · `evidence: Sources/App/Services/Crypto/PrivateStaging.swift` · `qa: ENCRYPT-05`
- **ENC-011** When the user has not changed the backup setting, the data folder is not excluded from Time Machine or other system backups.
  `surface: background` · `evidence: Sources/App/Services/BackupExclusion.swift, Sources/App/Services/AppSettings.swift` · `qa: BACKUP-01`
- **ENC-012** When FileVault is off, Settings shows "Encrypt this Mac's disk with FileVault" with an "Open Settings" button.
  `surface: ui` · `evidence: Sources/App/Services/DiskEncryption.swift, Sources/App/Views/SettingsView.swift` · `qa: ENCRYPT-01`
- **ENC-013** When some records cannot be read, a notice such as "1 record couldn't be read" is shown, the originals are left untouched, and the rest of the folder still opens.
  `surface: ui` · `evidence: Sources/App/Views/DamagedRecordsNotice.swift` · `qa: BACKUP-07`
- **ENC-014** When the patient database cannot be opened, a banner headed "Notes and chat can't be saved right now" explains why, offers recovery steps that never tell the user to delete anything, and records already on disk are not overwritten.
  `surface: ui` · `evidence: Sources/App/Views/DatabaseUnavailableBanner.swift, Sources/App/Services/Features/Doctor/DatabaseFailureGuidance.swift` · `qa: BACKUP-07`
- **ENC-015** When the user types a passphrase shorter than 12 characters during setup, Continue is disabled and the form shows "Use at least 12 characters.".
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: ENCRYPT-02`
- **ENC-016** When encryption is on, the folder and file names, the data-format stamp, the keystore, the audit log and each session's metadata file remain readable rather than encrypted.
  `surface: invariant` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, docs/ENCRYPTION.md` · `qa: ENCRYPT-05`
- **ENC-017** When the user chooses "Change Passphrase…", they must enter the current passphrase and a new one of at least 12 characters, and the recovery key keeps working.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: ENCRYPT-08`
- **ENC-018** When the user creates a new recovery key with "Replace Recovery Key", the previous recovery key stops unlocking the folder.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/Keystore.swift` · `qa: ENCRYPT-08`
- **ENC-019** When the user tries to save the recovery key inside the encrypted data folder, it is refused with "Save the recovery key outside your encrypted data folder — a copy kept beside your data would unlock it.".
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/RecoveryKeyDocument.swift` · `qa: ENCRYPT-03`
- **ENC-020** When the user taps "Copy Words" on the recovery key, the words go to this Mac's clipboard only, clipboard managers are asked not to keep them, and the button reads "Copied to clipboard".
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/PHIPasteboard.swift` · `qa: ENCRYPT-03`
- **ENC-021** When the user chooses "Save as PDF…" or "Print…" for the recovery key, the document is titled "Aletheia — Emergency Recovery Key".
  `surface: ui` · `evidence: Sources/App/Services/Crypto/RecoveryKeyDocument.swift, Sources/App/Views/EncryptionSettingsView.swift` · `qa: ENCRYPT-03`
- **ENC-022** When the user must confirm the recovery key during setup, "Encrypt my data" stays unavailable until they tick "I have saved or printed my emergency recovery key and stored it safely." and "I understand my data can't be recovered if I lose my passphrase and emergency recovery key.".
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift` · `qa: ENCRYPT-04`
- **ENC-023** When setup starts, "Remember on this Mac" is already on, and on the unlock screen the same toggle starts off.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Views/FolderUnlockView.swift` · `qa: ENCRYPT-04`
- **ENC-024** When this Mac's keychain cannot keep the key, setup finishes with the message that the user will be asked for the passphrase on each launch.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/DeviceKeyStore.swift` · `qa: ENCRYPT-04`
- **ENC-025** When some existing items cannot be converted during setup, a message says how many couldn't be converted and that they will be encrypted the next time they are saved.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/DataMigrator.swift` · `qa: ENCRYPT-04`
- **ENC-026** When the user enters a wrong passphrase, the message "That passphrase didn't unlock the encrypted data. Check it and try again." is shown, and a wrong recovery key gives "That recovery key didn't unlock the encrypted data. Check the words and try again.".
  `surface: ui` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, Sources/App/Views/FolderUnlockView.swift` · `qa: ENCRYPT-07`
- **ENC-027** When attempts are throttled, the unlock screen tells the user how many seconds to wait before trying again.
  `surface: ui` · `evidence: Sources/App/Services/Crypto/UnlockThrottle.swift, Sources/App/Views/FolderUnlockView.swift` · `qa: ENCRYPT-07`
- **ENC-028** When the user mistypes a word of the recovery key, that mistake does not count as a failed attempt toward the wait.
  `surface: ui` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, Sources/App/Services/Crypto/RecoveryKey.swift` · `qa: ENCRYPT-07`
- **ENC-029** When the app locks, the folder key is dropped from memory, the search index is deleted, and the on-device model is unloaded.
  `surface: background` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, Sources/App/Services/AppLock.swift` · `qa: LOCK-06`
- **ENC-030** When the app is locked and later unlocked, a remembered key is loaded again only after the user has authenticated to the app.
  `surface: background` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, Sources/App/Services/AppLock.swift` · `qa: ENCRYPT-06`
- **ENC-031** When the encrypted folder's keystore file is missing, a screen titled "The encryption keystore is missing" offers "Use a different data folder…" and "Check again".
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: ENCRYPT-06`
- **ENC-032** When the user turns off encryption, a "Turn off encryption?" confirmation with "Turn Off and Decrypt" runs and files are decrypted before the key is removed.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/DataMigrator.swift` · `qa: ENCRYPT-09`
- **ENC-033** When any item cannot be decrypted while turning encryption off, the message "Encryption is still on: N item(s) couldn't be decrypted, so nothing was removed. Try again." is shown and encryption stays on.
  `surface: ui` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: ENCRYPT-09`
- **ENC-034** When encryption is on, the search index exists only while unlocked and is deleted on lock, on turning encryption off, and at launch while locked.
  `surface: background` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, Sources/App/Services/Search` · `qa: ENCRYPT-09`
- **ENC-035** When a recording is in progress, its audio is held unencrypted in a private staging folder until the user stops it, and an interrupted recording is recovered and encrypted at the next launch.
  `surface: background` · `evidence: Sources/App/Services/OrphanAudioSweep.swift, Sources/App/Services/Crypto/PrivateStaging.swift` · `qa: ENCRYPT-05`
- **ENC-036** When Aletheia launches, leftover temporary decrypted files from earlier runs are swept from its private scratch folder.
  `surface: background` · `evidence: Sources/App/Services/Crypto/PrivateStaging.swift` · `qa: ENCRYPT-05`
- **ENC-037** When the build is not a developer build and the folder is not already encrypted, no encryption setup is offered in Settings or first run.
  `surface: ui` · `evidence: Sources/App/Services/Crypto/AtRestEncryptionFeatureModule.swift, Sources/App/Views/FirstRunView.swift, README.md` · `qa: ENCRYPT-01`
- **ENC-038** When the data folder is already encrypted, the user can unlock and manage it, including turning encryption off, in any build.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift, Sources/App/Services/Crypto/AtRestEncryptionFeatureModule.swift` · `qa: ENCRYPT-01`
- **ENC-039** When encryption is turned on, a safety copy of the database is made first and older unencrypted database copies in the hidden backups folder are deleted.
  `surface: background` · `evidence: Sources/App/Services/Crypto/DataMigrator.swift, Sources/App/Services/Crypto/DatabaseSnapshotManager.swift` · `qa: BACKUP-04`
- **ENC-040** When the encryption pane is locked, it shows "Unlock from the main window to manage encryption." and no management buttons.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift` · `qa: ENCRYPT-06`
- **ENC-041** When no data folder is chosen, "Turn On…" is disabled with "Choose a data folder in General first.".
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift` · `qa: ENCRYPT-02`
- **ENC-042** When the Encryption pane is shown, a chip reads "Off", "On", "On — locked" or "Keystore missing" to match the folder's state.
  `surface: ui` · `evidence: Sources/App/Views/EncryptionSettingsView.swift` · `qa: ENCRYPT-02`
- **ENC-043** When the user clicks "Use a different data folder…" on the unlock screen, they can pick another folder instead of unlocking.
  `surface: ui` · `evidence: Sources/App/Views/FolderUnlockView.swift` · `qa: ENCRYPT-06`
- **ENC-044** When the volume is known to be unencrypted, adding a new patient, session or recording is blocked with an alert titled "Turn on FileVault" offering "Open System Settings" and "Cancel".
  `surface: ui` · `evidence: Sources/App/Services/DiskEncryption.swift, Sources/App/Services/AppModel.swift, Sources/App/Views/RecordingMenuBar.swift` · `qa: PATIENT-09`
- **ENC-045** When the FileVault state cannot be determined, "Couldn't confirm disk encryption" is shown once per launch with a "Continue" button and the action then proceeds.
  `surface: ui` · `evidence: Sources/App/Services/DiskEncryption.swift` · `qa: PATIENT-09`
- **ENC-046** When FileVault is off, existing records can still be opened and exported.
  `surface: invariant` · `evidence: Sources/App/Services/DiskEncryption.swift` · `qa: PATIENT-09`
- **ENC-047** When a note or chat cannot be saved, a strip says "Couldn't save your" followed by what failed, that it is still on screen, and to check the disk isn't full.
  `surface: ui` · `evidence: Sources/App/Views/DatabaseUnavailableBanner.swift` · `qa: BACKUP-07`
- **ENC-048** When the database banner is shown for a damaged database, its restore steps rename the damaged file rather than deleting it, and the app stays usable for reading.
  `surface: ui` · `evidence: Sources/App/Services/Features/Doctor/DatabaseFailureGuidance.swift, Sources/App/Views/DatabaseUnavailableBanner.swift` · `qa: BACKUP-07`
- **ENC-049** When the saved access to the chosen data folder has gone stale, it is refreshed silently, and if it cannot be resolved no data folder is selected.
  `surface: background` · `evidence: Sources/App/Services/SecurityScopedBookmark.swift` · `qa: SETTINGS-02`
- **ENC-050** When the user opens Settings, the Data folder caption reads "Everything lives here. Changing it moves nothing; point it at an existing Aletheia folder to switch.".
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-02`

## App lock and privacy shield (LCK)

- **LCK-001** When App lock is on and the Mac can authenticate, launching the app shows a lock screen and no patient information is visible until the user unlocks.
  `surface: ui` · `evidence: Sources/App/Services/AppLock.swift, Sources/App/Views/LockView.swift` · `qa: LOCK-01`
- **LCK-002** When the Mac sleeps, the display sleeps, the screen locks or another user is switched to, Aletheia locks.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift` · `qa: LOCK-02`
- **LCK-003** When "Lock when Aletheia is hidden" is on and the user hides Aletheia with the hide shortcut, it locks.
  `surface: ui` · `evidence: Sources/App/Services/AppLock.swift, Sources/App/Views/SettingsView.swift` · `qa: LOCK-03`
- **LCK-004** When the app sits unused for the chosen time (Never, 1, 5, 15, 30 or 60 minutes), it locks, and on a new install the choice is 15 minutes.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift, Sources/App/Views/SettingsView.swift, Sources/App/Services/AppLock.swift` · `qa: LOCK-03`
- **LCK-005** When App lock is off, the "Auto-lock after" control is disabled.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: LOCK-03`
- **LCK-006** When the app is locked, patient content in every window, sheet, popover and the menu-bar panel is covered or hidden, and keyboard and mouse input to hidden windows is ignored.
  `surface: ui` · `evidence: Sources/App/Services/LockCoverPolicy.swift, Sources/App/Services/WindowSharingPolicy.swift` · `qa: LOCK-04`
- **LCK-007** When the app locks, the cover goes up immediately, and the Touch ID or password prompt appears only once the app is active.
  `surface: ui` · `evidence: Sources/App/Services/AppLock.swift` · `qa: LOCK-01`
- **LCK-008** When a save or open file panel is showing while locked, it stays visible because it shows only file names.
  `surface: ui` · `evidence: Sources/App/Services/WindowSharingPolicy.swift` · `qa: LOCK-04`
- **LCK-009** When the app is locked, its windows are excluded from screen capture and screen sharing regardless of settings.
  `surface: invariant` · `evidence: Sources/App/Services/WindowSharingPolicy.swift, Sources/App/Views/SettingsView.swift` · `qa: LOCK-05`
- **LCK-010** When "Hide Aletheia from screen sharing" is on, which is the default, all Aletheia windows including sheets, alerts and the menu-bar panel are hidden from screen sharing and screenshots by other apps.
  `surface: ui` · `evidence: Sources/App/Services/WindowSharingPolicy.swift, Sources/App/Views/SettingsView.swift` · `qa: LOCK-05`
- **LCK-011** When the user turns on "Allow screen sharing this session", capture is allowed until Aletheia quits, and the setting is off again at the next launch.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AppSettings.swift` · `qa: LOCK-05`
- **LCK-012** When a notification is posted for a finished transcript, a transcription problem, a recording left on disk, a ready summary, a long recording or an export, it names no patient and no date unless "Show patient names in notifications" is on, which it is not by default.
  `surface: ui` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/AppSettings.swift, Sources/App/Views/SettingsView.swift` · `qa: NOTIFY-07`
- **LCK-013** When the user copies patient information, it goes to the clipboard of this Mac only, clipboard managers are asked not to keep it, and it is not cleared automatically afterwards.
  `surface: background` · `evidence: Sources/App/Services/PHIPasteboard.swift` · `qa: LOCK-07`
- **LCK-014** When the user types or selects patient text anywhere in the app, system Writing Tools are not offered.
  `surface: ui` · `evidence: Sources/App/Views/Theme/ThemeWritingTools.swift, CLAUDE.md` · `qa: LOCK-08`
- **LCK-015** When App lock is on and the user cancels the unlock prompt, no error is shown and the prompt does not return until the app is switched away from and back to.
  `surface: ui` · `evidence: Sources/App/Services/AppLock.swift` · `qa: LOCK-02`
- **LCK-016** When unlocking fails for a reason other than cancelling, an error is shown on the lock screen.
  `surface: ui` · `evidence: Sources/App/Services/AppLock.swift, Sources/App/Views/LockView.swift` · `qa: LOCK-02`
- **LCK-017** When a recording or transcription is running as the app locks, the folder key is kept until that work ends and then dropped.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: LOCK-06`
- **LCK-018** When the app locks, Spotlight entries are cleared and the on-device model is unloaded.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift` · `qa: SEARCH-12`
- **LCK-019** When the user unlocks, the inactivity clock restarts.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift` · `qa: LOCK-03`
- **LCK-020** When a notification is posted with patient names on, the patient's full name and the session date appear in it, except export notices which stay generic.
  `surface: ui` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift` · `qa: NOTIFY-06`
- **LCK-021** When macOS has not allowed notifications for Aletheia, no notification is posted.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift` · `qa: NOTIFY-01`
- **LCK-022** When a recording has run for over 90 minutes, a "Still recording" notification asks whether the user forgot to end it.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift` · `qa: RECORD-08`
- **LCK-023** When the user clicks a window whose hidden sheet blocks it while locked, an unlock is requested.
  `surface: ui` · `evidence: Sources/App/Services/WindowSharingPolicy.swift` · `qa: LOCK-04`
- **LCK-024** When the encrypted folder's key is kept on this Mac, App lock is on whatever the saved setting says, so the key is never reachable without Touch ID or the password.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: LOCK-09`
- **LCK-025** When the key is kept on this Mac, Settings shows App lock on and unchangeable, and says why.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: LOCK-10`
- **LCK-026** When the key is not kept on this Mac, App lock can be turned off, after a fresh Touch ID or password check.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/SensitiveActionGate.swift` · `qa: LOCK-11`
- **LCK-027** When the app opens locked, the folder key is not loaded and no patient data is readable; a successful Touch ID or password check opens it with no passphrase.
  `surface: background` · `evidence: Sources/App/AletheiaApp.swift, Sources/App/Services/AppLock.swift` · `qa: LOCK-12`
- **LCK-028** When the app is installed fresh, "Lock when Aletheia is hidden" is on; an install that saved it as off keeps it off.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift, Sources/App/Views/SettingsView.swift` · `qa: LOCK-13`
- **LCK-029** When deleting a recording leaves any audio behind, including in the temporary audio folder, the app reports that it wasn't deleted instead of reporting success.
  `surface: background` · `evidence: Sources/App/Services/Store.swift` · `qa: LOCK-14`

## Audit log (AUD)

- **AUD-001** When the user unlocks or locks the app (with App lock on), changes encryption, changes the passphrase, exports a record or the audit log, deletes a patient, or recovers a recording, a dated entry is added to the activity log shown in Settings.
  `surface: ui` · `evidence: Sources/App/Services/AuditLog.swift, Sources/App/Views/Settings/AuditLogSection.swift, scripts/audit-unwired.txt` · `qa: SECURITY-04`
- **AUD-002** When the user reads the activity log, entries carry no patient names or note content.
  `surface: invariant` · `evidence: Sources/App/Services/AuditLog.swift, PRIVACY.md` · `qa: SECURITY-04`
- **AUD-003** When anyone edits or deletes an existing activity-log entry, the change is rejected with "audit log is append-only".
  `surface: invariant` · `evidence: Sources/App/Services/AuditLog.swift` · `qa: SECURITY-06`
- **AUD-004** When the log is tampered with outside the app, "Verify integrity & export audit report" shows "Integrity check failed at entry #N" with the reason.
  `surface: ui` · `evidence: Sources/App/Services/AuditLog.swift, Sources/App/Views/Settings/AuditLogSection.swift` · `qa: SECURITY-06`
- **AUD-005** When the user opens the activity log with many entries, it is shown in pages with a caption that explains what is kept.
  `surface: ui` · `evidence: Sources/App/Views/Settings/AuditLogSection.swift` · `qa: SECURITY-04`
- **AUD-006** When the log verifies cleanly, "Integrity verified: all N entries intact." is shown and an audit report text file is saved.
  `surface: ui` · `evidence: Sources/App/Views/Settings/AuditLogSection.swift, Sources/App/Services/AuditLog.swift` · `qa: SECURITY-05`
- **AUD-007** When the log cannot be verified, for example because its signing key is unavailable, "Audit log unverifiable:" is shown with the reason.
  `surface: ui` · `evidence: Sources/App/Services/AuditLog.swift, Sources/App/Views/Settings/AuditLogSection.swift` · `qa: SECURITY-05`
- **AUD-008** When the activity log is empty, it shows "No activity recorded yet. App unlocks are only logged when app lock is on." and the export buttons are disabled.
  `surface: ui` · `evidence: Sources/App/Views/Settings/AuditLogSection.swift` · `qa: SECURITY-04`
- **AUD-009** When the activity log is shown, pages hold 25 entries, newest first, with a "Showing a–b of N entries, newest first." line and Newer and Older buttons.
  `surface: ui` · `evidence: Sources/App/Views/Settings/AuditLogSection.swift` · `qa: SECURITY-04`
- **AUD-010** When an entry is listed, it shows its action name, a timestamp, and a detail line with the actor and the first 8 characters of an opaque record id.
  `surface: ui` · `evidence: Sources/App/Views/Settings/AuditLogSection.swift, Sources/App/Services/AuditLog.swift` · `qa: SECURITY-04`
- **AUD-011** When patients are deleted, their activity-log entries remain.
  `surface: invariant` · `evidence: Sources/App/Services/AuditLog.swift` · `qa: SECURITY-04`
- **AUD-012** When an older text audit log exists, its lines are imported once and shown with the actor "unknown".
  `surface: background` · `evidence: Sources/App/Services/AuditLog.swift` · `qa: BACKUP-07`
- **AUD-013** When the user exports a record, the entry says what was exported and in which format, such as "Session, <format>" or "Patient records, zip of N sessions".
  `surface: ui` · `evidence: Sources/App/Services/AuditLog.swift, Sources/App/Services/AppModel.swift` · `qa: SECURITY-04`
- **AUD-014** When the activity log is shown, its caption says backups and viewing records are not recorded yet.
  `surface: ui` · `evidence: Sources/App/Views/Settings/AuditLogSection.swift` · `qa: SECURITY-04`

## Data format and upgrades (DAT)

- **DAT-001** When the data folder was written by an older version, opening it upgrades it in place and records the new version.
  `surface: background` · `evidence: Sources/App/Services/DataSchema.swift, Sources/App/Services/Persistence/SchemaMigrator.swift, Sources/App/Services/Store.swift` · `qa: BACKUP-05`
- **DAT-002** When the data folder or database was written by a newer version, this version does not change it and an "Update Aletheia" alert tells the user to update before adding or changing anything.
  `surface: ui` · `evidence: Sources/App/Services/Store.swift, Sources/App/Views/RootView.swift, Sources/App/Services/DataSchema.swift` · `qa: BACKUP-06`
- **DAT-003** When an upgrade changes patient folder names, patients and sessions keep their identity and a copy of the original patient and session information files is retained.
  `surface: background` · `evidence: Sources/App/Services/PatientFolderMigration.swift, Sources/App/Services/BackupLayout.swift` · `qa: BACKUP-05`
- **DAT-004** When a patient record cannot be read during an upgrade, it is left untouched, reported as damaged, and the upgrade is tried again on the next open.
  `surface: background` · `evidence: Sources/App/Services/PatientFolderMigration.swift, Sources/App/Services/Store.swift` · `qa: BACKUP-07`
- **DAT-005** When an upgrade needs records that are still locked, nothing is changed until the user unlocks and it is retried.
  `surface: background` · `evidence: Sources/App/Services/PatientFolderMigration.swift, Sources/App/Services/Store.swift` · `qa: BACKUP-06`
- **DAT-006** When the database format is upgraded and the database already holds data, a safety copy is kept first, and a brand-new database takes no copy.
  `surface: background` · `evidence: Sources/App/Services/Persistence/MigrationBackup.swift, Sources/App/Services/Persistence/SQLitePersistenceCore.swift` · `qa: BACKUP-05`
- **DAT-007** When the safety copy before a database upgrade cannot be written, the upgrade is refused, the data is left untouched and it is retried at the next launch.
  `surface: ui` · `evidence: Sources/App/Services/Persistence/SQLitePersistenceCore.swift, Sources/App/Services/Persistence/DatabaseOpenFailure.swift` · `qa: BACKUP-06`
- **DAT-008** When a database upgrade fails part-way, it is rolled back and the banner explains that notes and chat can't be saved.
  `surface: ui` · `evidence: Sources/App/Services/Persistence/SQLitePersistenceCore.swift, Sources/App/Views/DatabaseUnavailableBanner.swift` · `qa: BACKUP-06`
- **DAT-009** When the database was written by a newer version, the banner shows "Database format vN; this version of Aletheia understands up to vM." and the file is left untouched.
  `surface: ui` · `evidence: Sources/App/Services/Persistence/SQLitePersistenceCore.swift, Sources/App/Views/DatabaseUnavailableBanner.swift` · `qa: BACKUP-06`
- **DAT-010** When the patient folder upgrade cannot finish, an "Update Aletheia" alert says the original records and migration backup were kept, and creating or saving records is refused.
  `surface: ui` · `evidence: Sources/App/Services/Store.swift, Sources/App/Views/RootView.swift` · `qa: BACKUP-06`
- **DAT-011** When the patient folder upgrade would collide with an existing name or identity, it stops before moving anything.
  `surface: background` · `evidence: Sources/App/Services/PatientFolderMigration.swift` · `qa: BACKUP-05`
- **DAT-012** When a patient is about to be deleted, a snapshot of the database is saved and only the newest 5 snapshots are kept.
  `surface: background` · `evidence: Sources/App/Services/Crypto/DatabaseSnapshotManager.swift, Sources/App/Services/Store.swift` · `qa: BACKUP-04`

## Doctor and security posture (DOC)

- **DOC-001** When the user runs Doctor, it lists checks grouped as Data folder, Database, Encryption, Snapshots & backups, Records and Tools & permissions, each with an "OK", "Warning" or "Problem" result and a short explanation.
  `surface: ui` · `evidence: Sources/App/Views/DoctorView.swift, Sources/App/Services/Features/Doctor/DoctorRunner.swift` · `qa: SECURITY-07`
- **DOC-002** When the user copies the Doctor report, patient names, session names, note text and file paths are replaced with placeholders, though on-screen details may show full paths.
  `surface: ui` · `evidence: Sources/App/Views/DoctorView.swift, Sources/App/Services/Features/Doctor/DoctorModel.swift` · `qa: SECURITY-08`
- **DOC-003** When the user opens the security posture card in Settings → Security, it lists App lock, Automatic logoff (only when app lock is on), At-rest encryption (only when encryption is offered or the folder is already encrypted), Audit log, FileVault, Network activity and On-device only, each marked OK, Review or Info.
  `surface: ui` · `evidence: Sources/App/Views/SecurityPostureView.swift, Sources/App/Services/SecurityPosture.swift` · `qa: SECURITY-01`
- **DOC-004** When the user opens Network access, it shows whether the main app can connect to the internet, and lists the helper's only hosts and downloads (update check and opted-in model downloads).
  `surface: ui` · `evidence: Sources/App/Services/NetworkHelper/NetworkAccessStatus.swift, Sources/App/Views/Settings/NetworkAccessView.swift` · `qa: SECURITY-02`
- **DOC-006** When Doctor finishes, its headline summarizes the result, such as "All checks passed" or "1 problem, 2 warnings".
  `surface: ui` · `evidence: Sources/App/Views/DoctorView.swift, Sources/App/Services/Features/Doctor/DoctorModel.swift` · `qa: SECURITY-07`
- **DOC-007** When the user chooses "Copy report", the button reads "Copied", and the footer says the report holds no patient names, session names or note text.
  `surface: ui` · `evidence: Sources/App/Views/DoctorView.swift` · `qa: SECURITY-08`
- **DOC-008** When free disk space is under 1 GB Doctor warns, and under 100 MB it reports a problem.
  `surface: ui` · `evidence: Sources/App/Services/Features/Doctor/DoctorProbes.swift, Sources/App/Services/Features/Doctor/DoctorRunner.swift` · `qa: SECURITY-07`
- **DOC-009** When the data folder is kept out of Time Machine, Doctor shows a warning on the Time Machine row.
  `surface: ui` · `evidence: Sources/App/Services/Features/Doctor/DoctorRunner.swift` · `qa: BACKUP-02`
- **DOC-010** When the user opens the Network access card, it shows a "Copy" button for a signature-check command the user can run to verify it.
  `surface: ui` · `evidence: Sources/App/Views/Settings/NetworkAccessView.swift` · `qa: SECURITY-03`
- **DOC-011** When the security posture card is shown, its headline reads "Your data is well protected on this Mac" or "Some protections could be stronger".
  `surface: ui` · `evidence: Sources/App/Views/SecurityPostureView.swift, Sources/App/Services/SecurityPosture.swift` · `qa: SECURITY-01`

## Security guarantees (SEC)

- **SEC-001** When the app runs, the main app has no permission to make network connections.
  `surface: invariant` · `evidence: project.yml, scripts/check-entitlements.sh` · `qa: BUILD-01`
- **SEC-002** When the app runs, only the sandboxed helper can reach the network, and it is asked for fixed items by number and is never given patient data.
  `surface: invariant` · `evidence: project.yml, CLAUDE.md` · `qa: BUILD-14`
- **SEC-003** When the app is built, it requests only sandboxing, microphone input and user-selected file access, with calendar access added only in the development tier.
  `surface: invariant` · `evidence: project.yml, scripts/check-entitlements.sh` · `qa: BUILD-01`
- **SEC-004** When a build adds an analytics, telemetry, crash-reporting or advertising component, the build fails.
  `surface: invariant` · `evidence: scripts/check-no-telemetry-sdk.sh` · `qa: BUILD-13`
- **SEC-005** When the user opens AI settings, Apple Intelligence shows as "Off" with "Apple Intelligence is turned off on purpose." and cannot be chosen as an engine.
  `surface: ui` · `evidence: Sources/App/Services/Integrations/Integrations.swift, Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-06`
- **SEC-006** When text from transcripts or model drafts is placed in a model prompt, it is marked as reference material so it cannot pass for instructions.
  `surface: background` · `evidence: Sources/App/Services/UntrustedText.swift` · `qa: NOTE-16`
- **SEC-007** When a file is committed to the repository, a scan fails the build on secrets or patient-style filenames.
  `surface: background` · `evidence: scripts/scan-secrets.sh` · `qa: BUILD-13`
- **SEC-008** When the secret scan itself fails to run, the build fails rather than passing.
  `surface: background` · `evidence: scripts/scan-secrets.sh` · `qa: BUILD-13`
- **SEC-009** When transcript, summary or draft text contains a copy of the reference-material markers, they are defused so they cannot close the marked section early.
  `surface: background` · `evidence: Sources/App/Services/UntrustedText.swift` · `qa: NOTE-16`

## Backups (BAK)

- **BAK-001** When the user opens Settings → Backups, a banner says whether the data folder is kept out of Time Machine and iCloud backups (on by default).
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: BACKUP-01`
- **BAK-002** When the user turns on "Keep my data out of Time Machine & iCloud backups", the data folder is excluded from those backups and the banner says to keep a copy of your own.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/BackupExclusion.swift` · `qa: BACKUP-02`
- **BAK-003** When the "Keep my data out of Time Machine & iCloud backups" choice is on, it is applied again whenever the data folder changes and at each launch.
  `surface: background` · `evidence: Sources/App/Services/BackupExclusion.swift, Sources/App/Services/AppSettings.swift` · `qa: BACKUP-02`
- **BAK-004** When the user clicks "Show backups folder in Finder", the hidden backups folder opens, or the data folder if there is none yet.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: BACKUP-03`
- **BAK-005** When the user chooses "Export All Records…", an unencrypted copy of their records is saved.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AllRecordsExport.swift` · `qa: BACKUP-03`
- **BAK-006** When the Backups pane is shown, it explains that safety copies of the database are saved in a hidden backups folder before a database format change or an encryption change.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: BACKUP-01`
- **BAK-007** Backup archives are encrypted and are written to `.backups/archives/`; database safety copies still go to `.backups/snapshots` and `.backups/migrations`.
  `surface: invariant` · `evidence: Sources/App/Services/Crypto/BackupService.swift, Sources/App/Services/Crypto/BackupCoordinator.swift` · `qa: BACKUP-08`
- **BAK-008** When older backup folders exist, they are moved into the current hidden backups layout without overwriting anything.
  `surface: background` · `evidence: Sources/App/Services/BackupLayout.swift` · `qa: BACKUP-04`
- **BAK-009** When Doctor warns that the data folder is kept out of Time Machine, its next step names the pane "Settings > Backups" and the toggle "Keep my data out of Time Machine & iCloud backups".
  `surface: ui` · `evidence: Sources/App/Services/Features/Doctor/DoctorRunner.swift` · `qa: BACKUP-02`
- **BAK-010** When a backup archive is restored, it unlocks with Touch ID or the passphrase, or with the recovery key on a new Mac.
  `surface: ui` · `evidence: Sources/App/Services/Crypto/BackupService.swift, Sources/App/Services/Crypto/BackupCoordinator.swift` · `qa: BACKUP-09`

## Progress notes (NOT)

- **NOT-001** When the Notes tab is open, a segmented picker offers Summary, SOAP, DAP, BIRP and GIRP alongside "My Notes".
  `surface: ui` · `evidence: Sources/App/Models/ProgressNoteFormat.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-01`
- **NOT-002** Each format has its own note: switching formats shows that format's saved note or its empty state, and a note for one format is never overwritten by generating another.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Models/ProgressNoteFormat.swift` · `qa: NOTE-05`
- **NOT-003** When a format has no note yet, the pane shows "No <format> note yet" (for example "No SOAP note yet"), the text "Draft one from the transcript and your notes. You can edit it before it goes in the record.", and a "Generate <format> note" button that ⌘G also triggers.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/ShortcutCatalog.swift` · `qa: NOTE-02`
- **NOT-004** When the session has no transcript, the empty-state card says "Transcribe the session first, then draft the note from it." and its Generate button is disabled.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-02`
- **NOT-005** SOAP notes contain exactly the sections Subjective, Objective, Assessment, Plan in that order; DAP has Data, Assessment, Plan; BIRP has Behavior, Intervention, Response, Plan; GIRP has Goal, Intervention, Response, Plan. The AI cannot add, drop or reorder these sections.
  `surface: ui` · `evidence: Sources/App/Models/ProgressNoteFormat.swift, Sources/App/Services/Llama/NoteFormatGrammar.swift` · `qa: NOTE-04`
- **NOT-006** When the Summary format is chosen, the note is not forced into fixed headed sections.
  `surface: ui` · `evidence: Sources/App/Services/Llama/NoteFormatGrammar.swift, Sources/App/Models/ProgressNoteFormat.swift` · `qa: NOTE-04`
- **NOT-008** When a note is saved, a line-start, bullet or timestamp speaker label "Y:" or "C:" is rewritten to "You" or the client's first name ("the client" if there is none).
  `surface: ui` · `evidence: Sources/App/Services/SpeakerCodes.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-04`
- **NOT-010** When a note is saved, shown or copied, a first line that is only a chatty preamble such as "Here is a summary:" is removed, provided note content follows it.
  `surface: ui` · `evidence: Sources/App/Services/Markdown/NoteMarkdown.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-04`
- **NOT-011** A Length menu offers Concise, Natural (the default) and Detailed, and the chosen length controls how long the next generated note is.
  `surface: ui` · `evidence: Sources/App/Models/SummaryVerbosity.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-06`
- **NOT-012** The menu button reads "Length: <length> · <effort>" (for example "Length: Natural · Normal"), and the menu also offers an "AI effort" choice of Fast, Normal and Focus.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Models/AnswerEffort.swift` · `qa: NOTE-06`
- **NOT-013** Each format's instructions can be edited from the menu ("Edit <format> Prompt…", marked "(customized)" once changed) in a sheet titled "<format> prompt" whose caption says the transcript, your notes and comments, and the length setting are added automatically after the instructions.
  `surface: ui` · `evidence: Sources/App/Views/NoteInstructionsSheet.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-07`
- **NOT-014** In the instructions sheet, "Reset to Default" puts the built-in text in the field (disabled when it already matches), Cancel discards, and Save keeps the text; saving blank text or text identical to the default clears the customization.
  `surface: ui` · `evidence: Sources/App/Views/NoteInstructionsSheet.swift, Sources/App/Services/AppSettings.swift` · `qa: NOTE-07`
- **NOT-015** When the user sets custom instructions for a note format, they replace that format's whole editable instruction text, including its section layout and rules, while the length setting, formatting rules and reference-material handling still apply.
  `surface: invariant` · `evidence: Sources/App/Services/Prompts.swift, Sources/App/Views/NoteInstructionsSheet.swift` · `qa: NOTE-07`
- **NOT-016** Each format keeps its own custom instructions, and they persist across relaunch.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift, Sources/App/Views/NoteInstructionsSheet.swift` · `qa: NOTE-07`
- **NOT-017** While a note is generating, the format picker is locked and the pane shows a title ("Generating summary" or "Generating SOAP note"), one status line with elapsed time, and a progress bar that never goes backwards and never reaches full before the note is finished.
  `surface: ui` · `evidence: Sources/App/Models/NoteProgress.swift, Sources/App/Views/AIProgressView.swift` · `qa: NOTE-03`
- **NOT-018** The note text streams into view as it is written, and a Stop button ends generation, keeping the text written so far.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/StreamSmoother.swift` · `qa: NOTE-03`
- **NOT-019** If generation is stopped before any text arrives, or produces an empty result, the previously saved note is restored unchanged.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-05`
- **NOT-020** If generation fails, the pane returns to the previously saved note and a "Something went wrong" alert is shown rather than leaving a blank or half-written note.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-09`
- **NOT-021** When a note is requested while the AI is busy, the pane shows a clock status line ("Waiting for another note to finish…", "Waiting for the chat answer to finish…" or "Finishing a background digest, yours will run next.") with a Cancel button, the saved note stays visible, and generation starts when the earlier work finishes.
  `surface: ui` · `evidence: Sources/App/Services/InferenceQueue.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-08`
- **NOT-022** When a note for the session is already being written or waiting, even after leaving and reopening the session, requesting another shows "A note for this session is already being written."
  `surface: ui` · `evidence: Sources/App/Services/InferenceQueue.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-08`
- **NOT-023** When a note finishes with non-empty text and is saved, including one stopped part-way, a "Summary ready" notification is posted.
  `surface: background` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/Notifications/SessionNotifications.swift` · `qa: NOTIFY-04`
- **NOT-024** When Regenerate is pressed and the current note was edited by hand, the app first asks "Replace your edited note?" with Regenerate and Cancel; an unedited generated note is replaced without asking.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-10`
- **NOT-025** Edit opens a formatted editor for the note with a banner "Editing the <format> note. Regenerating asks before replacing your edits.", the format picker is locked and Regenerate is disabled while editing.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Views/RichNoteEditor.swift` · `qa: NOTE-10`
- **NOT-026** In the note editor, the Save button is enabled only when the edited text is non-blank and differs from what is saved (ignoring line-ending and surrounding whitespace differences); Cancel leaves the saved note untouched.
  `surface: ui` · `evidence: Sources/App/Services/NoteEditing.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-10`
- **NOT-027** The note editor shows headings, bold, italic and lists as formatted text (not raw "##" or "**"), with a toolbar and the shortcuts ⌘B bold, ⌘I italic, ⇧⌘7 bulleted list, ⇧⌘9 numbered list, ⇧⌘B body, ⇧⌘H heading, ⇧⌘J subheading, active only while typing in the editor.
  `surface: ui` · `evidence: Sources/App/Views/RichNoteEditor.swift, Sources/App/Services/ShortcutCatalog.swift` · `qa: NOTE-11`
- **NOT-028** Pasting into the note editor inserts plain text only, with no foreign styling.
  `surface: ui` · `evidence: Sources/App/Views/RichNoteEditor.swift` · `qa: NOTE-11`
- **NOT-029** The note is stored as Markdown text, so edits made in the formatted editor survive reopening and are what later AI questions read.
  `surface: invariant` · `evidence: Sources/App/Views/RichNoteEditor.swift, Sources/App/Services/Store.swift` · `qa: NOTE-11`
- **NOT-030** Each note is saved per format with a record of which transcript it was written from.
  `surface: invariant` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/NoteFreshness.swift` · `qa: NOTE-12`
- **NOT-031** If the transcript changes after a note was generated, the note shows the banner "Outdated: the transcript has changed since this note was generated." with a Regenerate button.
  `surface: ui` · `evidence: Sources/App/Views/OutdatedNoteBanner.swift, Sources/App/Services/NoteFreshness.swift` · `qa: NOTE-12`
- **NOT-032** The outdated banner is not shown for a note that has no recorded transcript marker or no text, while the note is generating or queued, or on the "My Notes" tab; its Regenerate is disabled when there is no transcript.
  `surface: ui` · `evidence: Sources/App/Services/NoteFreshness.swift, Sources/App/Views/OutdatedNoteBanner.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-12`
- **NOT-033** Editing a note by hand does not make it "outdated"; only a change to the transcript does.
  `surface: ui` · `evidence: Sources/App/Services/NoteFreshness.swift` · `qa: NOTE-12`
- **NOT-034** "My Notes" is the therapist's own free-text area (placeholder "Your private process notes for this session…"), saved automatically as they type, never marked outdated, and never regenerated by the AI.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Views/RichNoteEditor.swift` · `qa: NOTE-13`
- **NOT-035** When a note is drafted, the therapist's own notes are always included, comments are included only when "Include comments in drafts" is on, and resolved comments are always left out.
  `surface: ui` · `evidence: Sources/App/Services/Integrations/AssistantService.swift, Sources/App/Services/AppSettings.swift` · `qa: NOTE-04`
- **NOT-036** Settings has "Include comments in drafts" and "Include patient background", both on by default; when one is off, that material is not given to the AI.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift, Sources/App/Views/SettingsView.swift` · `qa: NOTE-04`
- **NOT-037** The transcript and summaries given to the AI are treated as material to summarize, not as instructions, so text inside a transcript that tells the AI to do something does not change how the note is written.
  `surface: invariant` · `evidence: Sources/App/Services/UntrustedText.swift, Sources/App/Services/Prompts.swift` · `qa: NOTE-16`
- **NOT-038** A session short enough for this Mac to read at once gets its note in a single pass reading the whole transcript at every effort level.
  `surface: background` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift, Sources/App/Services/ContextBudget.swift` · `qa: NOTE-14`
- **NOT-039** A session too long for this Mac to read at once gets its note from the session summary plus transcript passages, with lines mentioning a risk phrase (suicide, self-harm or violence wording, or the therapist's own added phrases) prioritized first, then the best passages for each section.
  `surface: background` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift` · `qa: NOTE-14`
- **NOT-040** Risk phrases are editable in Settings: the therapist can add, remove, clear (after confirming "Clear all risk phrases?") and reset (after confirming "Reset risk phrases?") them; empty and duplicate phrases are ignored, and matching is whole-word, case-insensitive and ignores apostrophe style.
  `surface: ui` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift, Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-09`
- **NOT-041** When a transcript is too long to read in one pass, drafting a note first builds the session summary if it is missing or out of date, and the status line reads "Generating <note title>. Processing transcript · Reading section N of M…" with elapsed time.
  `surface: background` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift, Sources/App/Models/NoteProgress.swift` · `qa: NOTE-14`
- **NOT-042** At Focus effort on a long session the draft is checked against the transcript passages, and the correction is used only if it is at least 60% as long, keeps every section heading, and leaves every risk-related sentence unchanged; otherwise the unchecked draft is kept.
  `surface: background` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift, Sources/App/Models/AnswerEffort.swift` · `qa: NOTE-14`
- **NOT-043** A long-session note is saved with a coverage line saying what was read and whether it was checked (for example "Checked against the passages." or "Not checked: the draft was too long to check."), and a stopped note says "Stopped early: this note is only what was written before you stopped."
  `surface: ui` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-14`
- **NOT-044** When the engine appears not to have read all the material, a stored non-empty note that is not being edited shows "The model may not have read all of the material; try again or lower the length."
  `surface: ui` · `evidence: Sources/App/Models/AIRunStats.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-14`
- **NOT-045** A note request too long for the Mac's reading capacity is refused with "This session is longer than this Mac can read at once" and advice to shorten the note instructions or comments; nothing is sent or silently cut.
  `surface: ui` · `evidence: Sources/App/Services/ContextBudget.swift, Sources/App/Services/Prompts.swift` · `qa: NOTE-14`
- **NOT-046** A therapist-written field (background, notes, comments) over about 100 pages (300,000 characters) is refused with "<field> is too long for the assistant to read: the limit is about 100 pages (300,000 characters). Shorten it and try again.", where the field is "The patient background", "The session notes" or "The margin comments".
  `surface: ui` · `evidence: Sources/App/Services/TherapistInput.swift` · `qa: NOTE-14`
- **NOT-047** A saved note is shown as formatted text, with headings, lists, quotes and code blocks displayed formatted, in a serif "note" look distinct from chat answers.
  `surface: ui` · `evidence: Sources/App/Views/MarkdownMessageView.swift, Sources/App/Services/Markdown/MarkdownDocument.swift` · `qa: NOTE-15`
- **NOT-048** Links and images written by the AI are never clickable or loaded: the visible text stays but no address is opened or fetched.
  `surface: invariant` · `evidence: Sources/App/Views/SafeMarkdown.swift, Sources/App/Views/MarkdownMessageView.swift` · `qa: NOTE-15`
- **NOT-049** A Mermaid flowchart or sequence diagram in a note or answer is drawn natively as a picture with a Diagram/Source toggle and a Copy menu ("Copy diagram as picture" or "Copy Mermaid source"); unsupported, malformed or oversize (over 60 nodes or 120 edges) diagrams show their source text instead.
  `surface: ui` · `evidence: Sources/App/Services/Markdown/MermaidDiagram.swift, Sources/App/Views/MermaidDiagramView.swift` · `qa: CHAT-14`
- **NOT-050** Diagrams are drawn without any web view, script or network use, in the app's theme colors for Light, Dark and Increase Contrast.
  `surface: invariant` · `evidence: Sources/App/Services/Markdown/MermaidDiagram.swift, Sources/App/Views/MermaidDiagramView.swift` · `qa: CHAT-14`
- **NOT-051** Copy puts the note on the clipboard as rich text, HTML and plain text with headings and lists intact and no Markdown symbols; the button then shows "Copied" for about 1.5 seconds.
  `surface: ui` · `evidence: Sources/App/Services/RichClipboard.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-15`
- **NOT-052** Copied note text is marked as sensitive so it is excluded from clipboard history and not synced to other devices, like other patient text.
  `surface: invariant` · `evidence: Sources/App/Services/PHIPasteboard.swift, Sources/App/Services/RichClipboard.swift` · `qa: NOTE-15`
- **NOT-053** A note can be exported from the note pane as PDF (the default), Word or Markdown; the file is named "<patient> - <yyyy-MM-dd> - <format>", and once saved an activity-log entry records the export.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Views/ExportButton.swift, Sources/App/Services/ExportFormat.swift` · `qa: EXPORT-10`
- **NOT-054** A note PDF is US Letter with 54-point margins in a Georgia serif face, black on white, up to 2,000 pages, and is produced in memory with no print panel or temporary file.
  `surface: ui` · `evidence: Sources/App/Services/NotePDF.swift` · `qa: EXPORT-10`
- **NOT-055** The Word export and the rich copy use the same styled text as the PDF, so headings and lists look the same in all three.
  `surface: ui` · `evidence: Sources/App/Services/NotePDF.swift, Sources/App/Services/RichClipboard.swift` · `qa: EXPORT-10`
- **NOT-056** Exporting a whole session as Markdown produces "# <patient>", "**Date:**", "## Summary" and "## Transcript" sections, or "_No transcript or summary recorded for this session yet._" when both are empty.
  `surface: ui` · `evidence: Sources/App/Services/MarkdownExporter.swift` · `qa: EXPORT-11`
- **NOT-057** Note generation uses only the on-device model and makes no network request; note text never leaves the Mac.
  `surface: invariant` · `evidence: Sources/App/Services/Integrations/Integrations.swift, README.md` · `qa: BUILD-07`
- **NOT-059** The note progress status for long sessions advances through "Processing transcript · Reading section N of M", "Combining sections", "Writing summary", "Reading passages", "Writing the note", "Checking" and "Writing corrections", with elapsed time.
  `surface: ui` · `evidence: Sources/App/Models/NoteProgress.swift, Sources/App/Views/AIProgressView.swift` · `qa: NOTE-14`
- **NOT-060** When the therapist picks a format in the Notes tab, that choice is remembered as the app-wide "Default progress note format" shown in Settings.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/AppSettings.swift` · `qa: NOTE-01`
- **NOT-061** When the session has no transcript, or while a note is being edited, Regenerate on an existing note is disabled.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-02`
- **NOT-062** When a note is saved, a sentence-opening "Y said" or "C said" (with other speech verbs) is rewritten to "You" or the client's first name, while titles such as "Dr. Y" are left alone.
  `surface: ui` · `evidence: Sources/App/Services/SpeakerCodes.swift` · `qa: NOTE-04`
- **NOT-063** When a note is shown, a "Label:" lead-in is bolded, a line holding only "Label:" becomes a subheading, and consecutive prose lines are separated by a blank line.
  `surface: ui` · `evidence: Sources/App/Services/Markdown/NoteMarkdown.swift` · `qa: NOTE-04`
- **NOT-064** Settings also offers a "Summary length" choice with the same Concise, Natural and Detailed options as the Length menu.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Models/SummaryVerbosity.swift` · `qa: SETTINGS-10`
- **NOT-065** The Length and AI effort menu is hidden while a note is generating, queued or being edited, and its help text says "Regenerate to apply a change".
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-06`
- **NOT-066** If the AI engine itself is unavailable when generating, an AI-engine problem alert with a retry is shown instead of "Something went wrong".
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-09`
- **NOT-067** When Regenerate is pressed right after Stop, the app waits briefly for the stopped note to finish unwinding and then starts without an alert.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/InferenceQueue.swift` · `qa: NOTE-05`
- **NOT-068** The "Summary ready" notification says "The AI summary for <patient>'s <date> session is ready to review." only when the setting to show patient names in notifications is on (off by default); otherwise it says "An AI summary is ready to review in Aletheia."
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/AppSettings.swift` · `qa: NOTIFY-04`
- **NOT-069** A Restore Previous button appears only when an earlier version of the note exists, and not while editing or queued.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-10`
- **NOT-070** When the risk phrase list is empty, Settings warns "No phrases. No lines will be prioritised for risk in long sessions."
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-09`
- **NOT-071** When the Focus check is skipped, the coverage line says why: "The check's result looked incomplete, so this is the unchecked draft." or "The check's correction changed a risk statement, so it was skipped and this is the unchecked draft."
  `surface: ui` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift` · `qa: NOTE-14`
- **NOT-072** When risk-flagged lines did not all fit in a long-session note, the coverage line says so and tells the therapist to check the transcript for risk.
  `surface: ui` · `evidence: Sources/App/Services/Digest/LongSessionNote.swift` · `qa: NOTE-14`

## Digests (DIG)

- **DIG-001** The app prepares behind-the-scenes summaries ("digests") of long transcripts on this Mac, so notes and questions about a long session or long history can use them; a session with a short transcript in a short history never needs one.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift, Sources/App/Services/Digest/DigestBuilder.swift` · `qa: DIGEST-01`
- **DIG-002** A session needs a summary when it has a transcript and either that transcript, or the patient's whole history, is longer than the room the AI has to read (less a margin for instructions).
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift, Sources/App/Services/Digest/DigestSchedulePolicy.swift` · `qa: DIGEST-01`
- **DIG-003** A transcript is split into sections of about ten minutes by timestamp (cut sooner if a section is very long), each summarized separately, then merged into one session summary.
  `surface: background` · `evidence: Sources/App/Services/Digest/TranscriptSections.swift, Sources/App/Services/Digest/DigestBuilder.swift` · `qa: DIGEST-02`
- **DIG-004** Untimed transcripts are sectioned as "[part 2 of 5]"; timed ones show ranges like "[12:30–22:10]"; a single line longer than a section is cut by characters.
  `surface: background` · `evidence: Sources/App/Services/Digest/TranscriptSections.swift` · `qa: DIGEST-02`
- **DIG-005** When section summaries do not fit in one merge, they are merged in groups that fit the budget, repeatedly.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestBuilder.swift` · `qa: DIGEST-02`
- **DIG-006** Building a summary shows progress on the Transcript tab such as "Processing transcript. Reading section 2 of 5… · 0:12" with a step bar, then "Combining sections…" and "Writing summary…".
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/Digest/DigestBuilder.swift` · `qa: DIGEST-02`
- **DIG-007** A failed build shows "Couldn't build the digest: …" with a Retry button on the Transcript tab; Retry clears the failure and queues the session first.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-05`
- **DIG-008** A stored summary counts as current only if its file version, instruction version, model and the transcript's fingerprint all match; any change means it is rebuilt.
  `surface: invariant` · `evidence: Sources/App/Services/Digest/SessionDigest.swift, Sources/App/Services/Digest/DigestBuilder.swift` · `qa: DIGEST-04`
- **DIG-009** Editing a transcript makes its summary stale and the app prepares a new one; unchanged sections are reused from saved section summaries.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestBuilder.swift, Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-04`
- **DIG-010** Finished section summaries are saved as they complete, so a paused, quit or failed build resumes from them; old saved sections are removed after the digest is saved.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestBuilder.swift` · `qa: DIGEST-02`
- **DIG-011** The summary file and the saved section summaries are encrypted like transcripts whenever encryption is on.
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/Digest/SessionDigest.swift` · `qa: ENCRYPT-05`
- **DIG-012** Summaries are built with the open session first, then the open patient's sessions, then the rest newest first.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-01`
- **DIG-013** Summaries are triggered by a transcript being saved (transcribed or edited), a session being opened, and a patient page or patient chat being opened, and the app scans for missing ones at launch and after unlock.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift, Sources/App/Views/PatientDetailView.swift` · `qa: DIGEST-01`
- **DIG-014** When every summary is ready the app rechecks about 15 minutes later.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-01`
- **DIG-015** Summary building never runs while the app is locked, while a recording is in progress, while a transcription is running, or while a note or question is running or waiting; "Prepare now" cannot override these.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestSchedulePolicy.swift, Sources/App/AletheiaApp.swift` · `qa: DIGEST-03`
- **DIG-016** Summary building also pauses while the user has paused it, in Low Power Mode, on battery power (unless "Prepare summaries on battery" is on; Low Power Mode still pauses), and for 10 minutes after a failed build.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestSchedulePolicy.swift, Sources/App/Services/PowerSource.swift` · `qa: DIGEST-03`
- **DIG-017** A pause cancels the build in progress (finished sections are kept) and building resumes by itself when the reason ends, except a pause the user chose, which stays until Resume is pressed.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-03`
- **DIG-018** A session whose build was interrupted is built first at the next launch, and a session that failed goes to the back of the queue.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-02`
- **DIG-019** "Prepare now" prioritizes that patient and overrides the user pause, Low Power Mode, battery and the failure backoff for all summary work, but never locked, recording, transcribing or a busy model; it resets when the work is done or when Pause is pressed.
  `surface: ui` · `evidence: Sources/App/Services/Digest/DigestSchedulePolicy.swift, Sources/App/Views/SummaryStatusRow.swift` · `qa: DIGEST-03`
- **DIG-020** The patient page and patient chat show "Summaries: N of M ready · <state>", or "Summaries: all N ready", with " · preparing" while a build runs.
  `surface: ui` · `evidence: Sources/App/Views/SummaryStatusRow.swift` · `qa: DIGEST-01`
- **DIG-021** The pause reason is spelled out: "paused while Aletheia is locked", "paused while recording", "paused while transcribing", "paused while the AI is working", "paused", "paused in Low Power Mode", "paused on battery", "paused after a problem, will try again soon".
  `surface: ui` · `evidence: Sources/App/Views/SummaryStatusRow.swift, Sources/App/Services/Digest/DigestSchedulePolicy.swift` · `qa: DIGEST-03`
- **DIG-022** The row's button is Resume when the user paused, Prepare now when paused for Low Power Mode, battery or a failure, and Pause otherwise (no button when all are ready); the row is hidden when the patient needs no summaries.
  `surface: ui` · `evidence: Sources/App/Views/SummaryStatusRow.swift, Sources/App/Services/Digest/DigestSchedulePolicy.swift` · `qa: DIGEST-03`
- **DIG-023** The row's help text reads "Summaries let questions about this patient cover sessions too long to read whole. They are prepared on this Mac while the AI isn't doing anything else, and pause during recording and transcription."
  `surface: ui` · `evidence: Sources/App/Views/SummaryStatusRow.swift` · `qa: DIGEST-03`
- **DIG-024** The user's pause choice and the "Prepare summaries on battery" setting persist across relaunch; the setting sits in Settings with the drafting options.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift, Sources/App/Views/SettingsView.swift` · `qa: DIGEST-03`
- **DIG-025** Scanning which sessions need summaries asks nothing of the model, so it continues while paused or while the AI is busy, except while locked, recording or transcribing.
  `surface: background` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-03`
- **DIG-026** Each summary step is a lowest-priority AI job: a note or question waiting in the queue starts before it, and the scheduler stops a running build when one waits.
  `surface: background` · `evidence: Sources/App/Services/InferenceQueue.swift, Sources/App/Services/Digest/DigestScheduler.swift` · `qa: DIGEST-03`
- **DIG-027** Summaries use the same on-device model as everything else; no transcript text leaves the Mac while building them.
  `surface: invariant` · `evidence: README.md, Sources/App/Services/Digest/DigestBuilder.swift` · `qa: DIGEST-01`
- **DIG-028** Summary text is fenced as reference material (not instructions) whenever it is given to the AI.
  `surface: invariant` · `evidence: Sources/App/Services/UntrustedText.swift, Sources/App/Services/Prompts+Digest.swift` · `qa: NOTE-16`
- **DIG-029** Patient-wide questions that read a history too long to send whole use stored summaries (recent sessions individually, older ones merged by month) when they exist; sessions without a summary yet contribute only their transcript openings.
  `surface: background` · `evidence: Sources/App/Services/Digest/PatientZoom.swift, Sources/App/Services/Digest/LocalToolLoop.swift` · `qa: CHAT-12`
- **DIG-031** The "N of M ready" count treats a current summary built by any model as ready, even if the model in use has since changed.
  `surface: ui` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift, Sources/App/Services/Store.swift` · `qa: DIGEST-01`
- **DIG-032** When a recording ends while the user's own pause is still on and summary work is pending, the pause stays, and an info alert says transcription is paused with work pending.
  `surface: ui` · `evidence: Sources/App/Services/Digest/DigestScheduler.swift, Sources/App/Services/Digest/DigestSchedulePolicy.swift` · `qa: DIGEST-03`

## Harness/eval (HAR)

- **HAR-001** Release builds contain no call-audio recording harness or LLM evaluation mode; both exist only in Debug builds and have no user-visible interface.
  `surface: invariant` · `evidence: Sources/App/Services/HarnessEval.swift, Sources/App/Services/HarnessRun.swift` · `qa: BUILD-04`

## Chat & Q&A (CHT)

- **CHT-001** When a session is open, its "Ask" tab shows a chat about that session.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift:269, Sources/App/Views/ChatPaneView.swift` · `qa: CHAT-01`
- **CHT-002** When the patient chat window is open, it has a minimum size of 640 by 440 points and a Done button that closes it.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatWindow.swift:40, Sources/App/Views/PatientChatView.swift:58` · `qa: CHAT-08`
- **CHT-003** When a chat is empty, it shows "Ask a question about <title>" and "The AI only knows what's in the transcript(s) here.", and the input placeholder reads "Ask about <title>…" (the title is "this session" for a session chat).
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:171-174, Sources/App/Views/ChatPaneView.swift:264, Sources/App/Views/SessionDetailView.swift:1433` · `qa: CHAT-08`
- **CHT-004** When the user presses Return, Enter, Shift-Return or Option-Return in the chat box, the question is sent.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift` · `qa: CHAT-02`
- **CHT-005** When the chat box is empty or holds only whitespace, or an answer is being written, the question cannot be sent.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:91` · `qa: CHAT-02`
- **CHT-006** When a question is sent, it appears as a message bubble on the trailing side, and the answer appears as formatted Markdown.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift, Sources/App/Views/MarkdownMessageView.swift` · `qa: CHAT-02`
- **CHT-007** When an answer is being written, the answer appears gradually, and a Stop button replaces Send.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:365, Sources/App/Services/StreamSmoother.swift` · `qa: CHAT-02`
- **CHT-008** When the user stops an answer, the part already shown is kept and saved in the conversation.
  `surface: ui` · `evidence: Sources/App/Views/ChatStreamRunner.swift:19, Sources/App/Views/ChatStreamRunner.swift:259` · `qa: CHAT-04`
- **CHT-009** When an answer streams, the conversation follows the newest text unless the reader has scrolled up, and sending a new question resumes following.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:519` · `qa: CHAT-04`
- **CHT-010** When a session is being recorded, the dictation microphone in the chat box is hidden.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:79` · `qa: CHAT-07`
- **CHT-011** When a question is queued behind other AI work, the chat shows a clock icon with a status line explaining the wait and a Cancel button.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:188-195, Sources/App/Services/InferenceQueue.swift` · `qa: CHAT-05`
- **CHT-012** When a session is reopened, its chat shows the earlier questions and answers.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/Repositories/ChatRepository.swift` · `qa: CHAT-06`
- **CHT-013** When a patient has several chat threads, a "Chats" sidebar lists them most recent first with relative times such as "Just now", and offers a New Chat button.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift:166-169, Sources/App/Views/PatientChatView.swift:535, Sources/App/Models/ChatThread.swift` · `qa: CHAT-09`
- **CHT-014** When the user opens a thread's context menu, it offers Rename and Delete.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift:204-205` · `qa: CHAT-17`
- **CHT-015** When a thread has no name given by the user, its title is taken from the first question (whitespace collapsed, at most 40 characters, cut at a word with "…"), and "New chat" if there is none.
  `surface: ui` · `evidence: Sources/App/Models/ChatThread.swift` · `qa: CHAT-09`
- **CHT-016** When no thread is selected, the window shows "No Chat Selected" with a New Chat button, and when there are no threads the sidebar shows "No chats yet".
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift:146-154, Sources/App/Views/PatientChatView.swift:186` · `qa: CHAT-09`
- **CHT-017** When patient chat threads are saved, they are stored in the local database, and an older single-conversation chat file is imported once.
  `surface: invariant` · `evidence: Sources/App/Services/Repositories/ChatRepository.swift, Sources/App/Models/ChatThread.swift` · `qa: CHAT-09`
- **CHT-018** When the patient page or patient chat is shown, it shows summary-preparation progress for that patient's history.
  `surface: ui` · `evidence: Sources/App/Views/SummaryStatusRow.swift, Sources/App/Views/PatientChatView.swift` · `qa: CHAT-08`
- **CHT-019** When a question fails, "Something went wrong" (or the engine-problem alert) appears and the question stays in the chat; choosing Retry on the engine alert removes the unanswered turn and asks it again.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift:119, Sources/App/Views/PatientChatView.swift:455, Sources/App/Views/SessionDetailView.swift:56-78` · `qa: CHAT-16`
- **CHT-020** When the chat is shown, an "AI effort" control offers Fast, Normal and Focus, is disabled while an answer is being written, and defaults to Normal.
  `surface: ui` · `evidence: Sources/App/Models/AnswerEffort.swift, Sources/App/Views/ChatPaneView.swift:311` · `qa: CHAT-05`
- **CHT-021** When effort is Fast, the answer makes no follow-up lookups; at Normal it makes up to 4 lookups in 1 round; at Focus up to 10 in 2 rounds.
  `surface: background` · `evidence: Sources/App/Models/AnswerEffort.swift, Sources/App/Services/Digest/LocalToolLoop.swift` · `qa: CHAT-12`
- **CHT-022** When material is too long to send whole, Fast reads at most about 7,500 characters for a session chat and 12,000 for a patient chat, while Normal and Focus may read as much as this Mac can hold.
  `surface: background` · `evidence: Sources/App/Models/AnswerEffort.swift` · `qa: CHAT-12`
- **CHT-023** When a session is too long to read at once, the session chat answers from the session summary and matching passages, plus follow-up lookups at Normal and Focus.
  `surface: background` · `evidence: Sources/App/Services/Digest/LocalToolLoop.swift` · `qa: CHAT-12`
- **CHT-024** When a follow-up lookup runs, it is read-only and limited to the current patient or session.
  `surface: invariant` · `evidence: Sources/App/Services/Digest/LocalToolLoop.swift:249-262` · `qa: CHAT-12`
- **CHT-025** When a patient-wide question fits, every session transcript is read whole, newest first.
  `surface: background` · `evidence: Sources/App/Services/PatientContextRetriever.swift:99-120, Sources/App/Services/Digest/PatientZoom.swift` · `qa: CHAT-12`
- **CHT-026** When a patient has a long history, the patient chat reads the background, the therapist's notes and comments, and stored session summaries (older ones merged by month), then search results and the sessions they point to, rather than every transcript.
  `surface: background` · `evidence: Sources/App/Services/Digest/PatientZoom.swift, Sources/App/Services/Digest/LocalToolLoop.swift` · `qa: CHAT-12`
- **CHT-027** When a patient-wide answer cites a session, the marker in the answer becomes the session date in parentheses such as "(Mar 4, 2025)".
  `surface: ui` · `evidence: Sources/App/Services/Citations.swift:225-250` · `qa: CHAT-11`
- **CHT-028** When an answer is still streaming, the raw text is shown, and the dates and Sources line appear when it finishes.
  `surface: ui` · `evidence: Sources/App/Services/Citations.swift, Sources/App/Views/PatientChatView.swift` · `qa: CHAT-11`
- **CHT-029** When the source-citations feature is not registered, the raw answer is shown without dates or a Sources line.
  `surface: ui` · `evidence: Sources/App/Services/SourceCitationsFeatureModule.swift` · `qa: CHAT-11`
- **CHT-030** When a patient answer finishes, it shows what was read, for example "Read: notes and comments from 22 sessions · transcript passages from 6 of 22 sessions (search: 14 mentions)", followed by the effort level.
  `surface: ui` · `evidence: Sources/App/Services/Citations.swift:170-192, Sources/App/Views/PatientChatView.swift` · `qa: CHAT-12`
- **CHT-031** When some sessions' transcripts could not be read, the what-was-read label says "N sessions could not be read, so answers may be incomplete".
  `surface: ui` · `evidence: Sources/App/Services/Citations.swift:188` · `qa: CHAT-12`
- **CHT-032** When a session chat answer finishes, it shows a "Read:" line saying what part of the session was read.
  `surface: ui` · `evidence: Sources/App/Services/Digest/LocalToolLoop.swift:1071, Sources/App/Views/SessionDetailView.swift` · `qa: CHAT-03`
- **CHT-033** When a search finds no match for a word the user asked about, the AI is told to say "no match found in the recorded sessions" rather than that the topic was never discussed.
  `surface: ui` · `evidence: Sources/App/Services/Prompts+Search.swift:8-20` · `qa: CHAT-12`
- **CHT-034** When a patient question is about one thing found by search and the transcripts total more than 18,000 characters, the chat sends the matching passages rather than whole transcripts, while a question that reads across sessions, or transcripts totalling 18,000 characters or less, are sent whole when they fit.
  `surface: background` · `evidence: Sources/App/Services/PatientContextRetriever.swift:50-55, Sources/App/Services/PatientContextRetriever.swift:105-120` · `qa: CHAT-12`
- **CHT-035** When transcripts, summaries and drafts are put in front of the model, they are fenced as reference material, any look-alike fence text inside them is neutralised, and the therapist's own question is not fenced.
  `surface: invariant` · `evidence: Sources/App/Services/UntrustedText.swift, Sources/App/Services/Prompts.swift` · `qa: NOTE-16`
- **CHT-036** When a session is too long for what this Mac can read at once, the question fails with a message beginning "This session is longer than this Mac can read at once", instead of silently dropping text.
  `surface: ui` · `evidence: Sources/App/Services/ContextBudget.swift` · `qa: NOTE-14`
- **CHT-037** When the reading budget is set, it scales with the Mac's memory: 16K tokens at 8 GB, 32K at 16 GB, 64K at 32 GB or more, one tier lower on Intel Macs, and never below 8K.
  `surface: invariant` · `evidence: Sources/App/Services/ContextBudget.swift, Sources/App/Services/HardwareCapabilities.swift` · `qa: CHAT-12`
- **CHT-038** When one therapist-typed field (question, notes, comments or background) is longer than 300,000 characters (about 100 pages), the request is refused with a message.
  `surface: ui` · `evidence: Sources/App/Services/TherapistInput.swift` · `qa: NOTE-14`
- **CHT-039** When more than 12,000 characters have built up since the last summary, the conversation is compacted before the next question is sent.
  `surface: background` · `evidence: Sources/App/Services/ChatMemory.swift:12, Sources/App/Views/ChatPaneView.swift` · `qa: CHAT-13`
- **CHT-040** When the chat has history, a Compact button appears and compacts the conversation on demand.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:98-101` · `qa: CHAT-13`
- **CHT-041** When a conversation has been compacted, a "Conversation compacted" card appears and the summary stands in for the older messages.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:380, Sources/App/Services/ChatMemory.swift` · `qa: CHAT-13`
- **CHT-042** When a compaction is stopped or fails, it is discarded and the conversation stays as it was.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift:463-487, Sources/App/Views/SessionDetailView.swift:1874-1904` · `qa: CHAT-13`
- **CHT-043** When the suggested-questions feature is in the build, an empty chat shows suggested starter questions (separate sets for a session and a patient) that disappear once the conversation has messages.
  `surface: ui` · `evidence: Sources/App/Services/SuggestedQuestionsFeatureModule.swift:20, Sources/App/Views/PatientChatView.swift:82, Sources/App/Views/SessionDetailView.swift:1436` · `qa: CHAT-01`
- **CHT-044** When the question asks for a diagram, flowchart or drawing, the AI is given diagram guidance, and otherwise it is not.
  `surface: background` · `evidence: Sources/App/Services/Prompts.swift:40-43` · `qa: CHAT-14`
- **CHT-046** When the user chats, the question, answer and transcript text stay on the Mac, and the main app has no network entitlement.
  `surface: invariant` · `evidence: scripts/check-entitlements.sh, Sources/App/Services/Integrations/Integrations.swift` · `qa: BUILD-07`
- **CHT-047** When the engine reports a known problem during a question (missing or unloadable model, out of memory), the engine-problem alert appears, and a successful fix asks the question again once.
  `surface: ui` · `evidence: Sources/App/Views/AIEngineProblemAlert.swift, Sources/App/Services/AIEngineProblem.swift` · `qa: NOTE-09`
- **CHT-048** When a patient question is being prepared, a status line shows the stage and elapsed time such as "Searching N sessions for “term”… · 0:03", with a Stop button.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift, Sources/App/Views/AIProgressView.swift` · `qa: CHAT-13`
- **CHT-049** When the model is reading the material, the status line reads "<stage>… · m:ss", and it changes to the writing stage once the first words arrive, with elapsed time counted from the start of the question.
  `surface: ui` · `evidence: Sources/App/Views/AIProgressView.swift, Sources/App/Models/NoteProgress.swift` · `qa: CHAT-05`
- **CHT-050** When the engine appears not to have read all of the material, the answer shows "The model may not have read all of the material; try again or lower the length."
  `surface: ui` · `evidence: Sources/App/Models/AIRunStats.swift, Sources/App/Views/ChatPaneView.swift` · `qa: CHAT-13`
- **CHT-052** When the user sends "/compact" with an optional focus phrase, the conversation is compacted around that focus, and no other slash command exists.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:337, Sources/App/Services/ChatMemory.swift` · `qa: CHAT-13`
- **CHT-053** When the patient chat window is closed and reopened, or the app is relaunched, the patient's threads are still there.
  `surface: ui` · `evidence: Sources/App/Services/Repositories/ChatRepository.swift` · `qa: CHAT-09`

- **CHT-054** When the patient page has no sessions, the "Ask about this patient" button is disabled, and otherwise it opens the patient's chat window (one window per patient, titled "Ask about <name>").
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift:231-239, Sources/App/AletheiaApp.swift:270-279, Sources/App/Views/PatientChatWindow.swift:27` · `qa: CHAT-08`
- **CHT-055** When an answer is being written, pressing Esc stops it, and when no answer is being written Esc does nothing in the chat.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:26-30, Sources/App/Views/ChatPaneView.swift:127` · `qa: CHAT-04`
- **CHT-056** When the user cancels a question that is still waiting in the queue, the unanswered question is removed from the chat.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift:319, Sources/App/Views/SessionDetailView.swift:1785` · `qa: CHAT-05`
- **CHT-057** When an answer is being written, switching threads, New Chat and Delete are disabled.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift` · `qa: CHAT-09`
- **CHT-058** When the Up or Down arrow key is pressed in the thread list, the selection moves to the neighbouring thread.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatView.swift` · `qa: CHAT-09`
- **CHT-059** When the effort is changed in session chat, patient chat or notes, each of the three keeps its own setting.
  `surface: ui` · `evidence: Sources/App/Models/AnswerEffort.swift` · `qa: CHAT-18`
- **CHT-060** When a session is short enough to fit, the session chat reads it whole.
  `surface: background` · `evidence: Sources/App/Services/Digest/LocalToolLoop.swift` · `qa: CHAT-03`
- **CHT-061** When a patient-wide question does not fit whole, the chat falls back to the passages matching the question, then to the newest sessions that fit, and last to the newest session's transcript cut short.
  `surface: background` · `evidence: Sources/App/Services/PatientContextRetriever.swift:113-130` · `qa: CHAT-12`
- **CHT-062** When a patient-wide answer cites at least one real session, a "Sources:" line lists only the cited sessions' dates.
  `surface: ui` · `evidence: Sources/App/Services/Citations.swift:245-249` · `qa: CHAT-11`
- **CHT-063** When an answer contains a marker that matches no session, the marker is left as written.
  `surface: ui` · `evidence: Sources/App/Services/Citations.swift:228` · `qa: CHAT-11`
- **CHT-064** When a therapist-typed field was only excerpted for lack of room, the what-was-read label adds a note saying so.
  `surface: ui` · `evidence: Sources/App/Services/Citations.swift:192, Sources/App/Services/TherapistInput.swift` · `qa: CHAT-12`
- **CHT-065** When a patient conversation leaves no room to read the sessions, the question fails with "This conversation leaves no room to read the sessions. Use Compact to shorten it, or start a new chat, and ask again."
  `surface: ui` · `evidence: Sources/App/Services/ContextBudget.swift` · `qa: CHAT-13`
- **CHT-066** When a therapist-typed field is under that limit but too big for the room, only the parts matching the question are sent, and the coverage label says they were excerpted.
  `surface: ui` · `evidence: Sources/App/Services/TherapistInput.swift` · `qa: CHAT-12`
- **CHT-067** When a question follows a compaction, the session material is read fresh for that question and not taken from the summary.
  `surface: background` · `evidence: Sources/App/Services/ChatMemory.swift` · `qa: CHAT-13`
- **CHT-068** When the patient being asked about has been deleted, the chat window shows "This patient is no longer available." with a Close button.
  `surface: ui` · `evidence: Sources/App/Views/PatientChatWindow.swift:30-33` · `qa: CHAT-10`
- **CHT-069** When the user copies a code block in an answer, its Copy button changes to "Copied"; other answer text has no Copy button.
  `surface: ui` · `evidence: Sources/App/Views/MarkdownMessageView.swift:240-300` · `qa: CHAT-15`
- **CHT-070** When the app quits while an answer is being written, the unfinished answer is not saved, and the earlier conversation is kept.
  `surface: invariant` · `evidence: Sources/App/Views/ChatStreamRunner.swift:253` · `qa: CHAT-06`
- **CHT-072** When text containing line breaks is pasted into the chat box and sent, each run of line breaks in the sent question becomes a single space.
  `surface: ui` · `evidence: Sources/App/Views/ChatPaneView.swift:35` · `qa: CHAT-02`

## AI engine & models (AIE)

- **AIE-001** When AI features run, the only engine used is the built-in on-device engine.
  `surface: invariant` · `evidence: Sources/App/Services/Integrations/Integrations.swift, Sources/App/Services/Integrations/AssistantBackend.swift` · `qa: SETTINGS-06`
- **AIE-002** When "Automatic" or "Built-in model" is chosen on any Mac, the built-in engine is used and Apple Intelligence is never used or offered.
  `surface: invariant` · `evidence: Sources/App/Services/Integrations/Integrations.swift, Sources/App/Services/Integrations/AssistantBackend.swift` · `qa: SETTINGS-06`
- **AIE-003** When AI features run, no AI text is sent over the network, and the main app has no network access.
  `surface: invariant` · `evidence: scripts/check-entitlements.sh, Sources/NetworkHelper/HelperFetcher.swift` · `qa: SETTINGS-06`
- **AIE-004** When the built-in engine is not linked into a build, AI actions fail with "The built-in AI model isn't available in this build of Aletheia." and no other engine is tried.
  `surface: ui` · `evidence: Sources/App/Services/Integrations/UnavailableAssistant.swift` · `qa: NOTE-09`
- **AIE-005** When a Mac has 16 GB or more, the recommended model is Llama 3.1 8B Instruct (about 6 GB download), and otherwise Gemma 4 E2B (about 2.8 GB), in every build tier.
  `surface: ui` · `evidence: Sources/App/Services/Llama/LlamaModel.swift, Sources/App/Services/ModelAdvisor.swift` · `qa: SETTINGS-07`
- **AIE-006** When the app is installed, the AI model is not bundled, and nothing is fetched until the user starts a download.
  `surface: ui` · `evidence: Sources/App/Services/Llama/LlamaModelDownloader.swift` · `qa: SETTINGS-07`
- **AIE-007** When a model downloads, only the sandboxed helper contacts the network, from a fixed list of https hosts, and the request carries no patient data.
  `surface: invariant` · `evidence: Sources/NetworkHelper/AssetCatalog.swift, Sources/NetworkHelper/HelperFetcher.swift, Sources/App/Services/NetworkHelper/NetworkHelperClient.swift` · `qa: BUILD-07`
- **AIE-008** When a downloaded model's checksum does not match, the file is deleted and the download fails.
  `surface: invariant` · `evidence: Sources/App/Services/NetworkHelper/ModelFileInstaller.swift, Sources/App/Services/ModelDigest.swift` · `qa: BUILD-09`
- **AIE-009** When a download is requested, it needs the model size plus 512 MB of free disk space and otherwise refuses with a message.
  `surface: ui` · `evidence: Sources/App/Services/Llama/LlamaModelDownloader.swift` · `qa: SETTINGS-08`
- **AIE-010** When a download is running, asking for the same model again joins it.
  `surface: background` · `evidence: Sources/App/Services/Llama/LlamaModelDownloader.swift` · `qa: SETTINGS-08`
- **AIE-011** When a model downloads, the status reads "Downloading model… (N%)" and then "Verifying downloaded model…" before the model becomes usable.
  `surface: ui` · `evidence: Sources/App/Services/Llama/LlamaModelDownloader.swift` · `qa: SETTINGS-08`
- **AIE-012** When a model is offered for download, the model's license name is shown with a link, and for the Llama model an "Acceptable Use Policy" link and "Built with Llama" attribution as well.
  `surface: ui` · `evidence: Sources/App/Views/ModelLicenseLink.swift, Sources/App/Services/Llama/LlamaModel.swift` · `qa: SETTINGS-07`
- **AIE-013** When a speech-to-text model is recommended, Apple silicon with 16 GB or more gets medium.en, Apple silicon with 8 GB or more small.en, Intel with 16 GB or more small.en, and anything else base.en.
  `surface: ui` · `evidence: Sources/App/Services/ModelAdvisor.swift, Sources/App/Services/HardwareCapabilities.swift` · `qa: SETTINGS-05`
- **AIE-014** When the prompt room is set, it scales with the Mac's memory: 16K tokens at 8 GB, 32K at 16 GB, 64K at 32 GB or more, one tier lower on Intel, and never below 8K.
  `surface: invariant` · `evidence: Sources/App/Services/ContextBudget.swift` · `qa: NOTE-14`
- **AIE-015** When a prompt is over the Mac's budget or the model's own limit, the request fails with an explanatory message rather than being cut short.
  `surface: invariant` · `evidence: Sources/App/Services/ContextBudget.swift, Sources/App/Services/Llama/LlamaContextSize.swift` · `qa: NOTE-14`
- **AIE-016** When the engine read less than 60% of the expected text (for prompts of at least about 500 tokens) or filled its window, the result shows the "may not have read all of the material" notice.
  `surface: ui` · `evidence: Sources/App/Models/AIRunStats.swift` · `qa: CHAT-13`
- **AIE-017** When a session is opened, the model is loaded in the background so the first request is faster.
  `surface: background` · `evidence: Sources/App/Views/SessionDetailView.swift:329, Sources/App/Services/Llama/LlamaAssistant.swift:109` · `qa: SETTINGS-08`
- **AIE-018** When 30 minutes pass without any AI request, the model is unloaded from memory, and a new request arriving first cancels that countdown.
  `surface: background` · `evidence: Sources/App/Services/Llama/LlamaEngine.swift` · `qa: SETTINGS-08`
- **AIE-019** When the app locks, the model is unloaded.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift:277, Sources/App/Services/Crypto/EncryptionManager.swift:413` · `qa: SETTINGS-08`
- **AIE-020** When the app or encrypted folder locks, the model or engine choice changes, a model download finishes, or a model is removed, the loaded model is released from memory.
  `surface: background` · `evidence: Sources/App/Services/AppSettings.swift:135, Sources/App/Services/Llama/LlamaModelDownloader.swift:46, Sources/App/Services/Llama/LlamaRuntime.swift:59` · `qa: SETTINGS-08`
- **AIE-021** When notes, session chats and patient chats are requested, they run one at a time, first come first served.
  `surface: background` · `evidence: Sources/App/Services/InferenceQueue.swift` · `qa: NOTE-08`
- **AIE-022** When a job waits, it shows why with one of: "Waiting for other work to finish…", "Finishing a background digest, yours will run next.", "Waiting for another note to finish…", "Waiting for the chat answer to finish…", "Still generating the note, your question will run next.", "Still answering another question, yours will run next."
  `surface: ui` · `evidence: Sources/App/Services/InferenceQueue.swift` · `qa: NOTE-08`
- **AIE-023** When a waiting job is cancelled it is dropped, and a running job is cancelled; at quit waiting jobs are dropped and the running job is cancelled.
  `surface: background` · `evidence: Sources/App/Services/InferenceQueue.swift` · `qa: NOTE-08`
- **AIE-024** When the AI model file is missing, the alert "The AI model isn't downloaded" explains the one-time download and offers "Download Model", "Copy Details" and "Cancel", and after a successful download the request is retried automatically.
  `surface: ui` · `evidence: Sources/App/Services/AIEngineProblem.swift, Sources/App/Views/AIEngineProblemAlert.swift` · `qa: NOTE-09`
- **AIE-025** When the model cannot be loaded, the alert "The AI model couldn't be loaded" offers "Re-download Model", for out-of-memory, generation failures or an unavailable engine "The AI engine hit a problem" offers "Try Again", and any other error is an ordinary "Something went wrong" alert.
  `surface: ui` · `evidence: Sources/App/Services/AIEngineProblem.swift, Sources/App/Views/AIEngineProblemAlert.swift` · `qa: NOTE-09`
- **AIE-026** When a fix is pending, at most one request per kind (note or chat) waits to be retried, Cancel or a failed fix discards it, and a failed fix shows "Couldn't fix the AI engine".
  `surface: ui` · `evidence: Sources/App/Views/AIEngineProblemAlert.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTE-09`
- **AIE-027** When "Copy Details" is used, it copies only technical information (problem, detail, backend, model, app version, macOS version) and no patient data.
  `surface: invariant` · `evidence: Sources/App/Services/AIEngineProblem.swift` · `qa: NOTE-09`
- **AIE-028** When the out-of-memory alert appears, its message advises a smaller model.
  `surface: ui` · `evidence: Sources/App/Services/AIEngineProblem.swift` · `qa: NOTE-09`
- **AIE-029** When the patient page or patient chat is shown and the model file is missing, a banner appears with a download button, progress, status text and the license link, and it re-checks when it appears and when the app becomes active.
  `surface: ui` · `evidence: Sources/App/Views/AIEngineProblemAlert.swift, Sources/App/Views/PatientChatView.swift, Sources/App/Views/PatientDetailView.swift` · `qa: SETTINGS-08`
- **AIE-030** When the menu-bar engine status is shown, it reads "Checking AI engine…", then "Built-in engine running · <model>", or "… running · <model> not downloaded" when the file is missing.
  `surface: ui` · `evidence: Sources/App/Services/EngineStatus.swift` · `qa: MENUBAR-02`
- **AIE-031** When the built-in model file is missing, the engine is still shown as reachable, as "not downloaded" rather than "not reachable".
  `surface: ui` · `evidence: Sources/App/Services/EngineStatus.swift` · `qa: MENUBAR-02`
- **AIE-032** When an AI run is in progress, a status line shows "<stage>… · m:ss", and sizes are shown as "~800 tokens" or "~31K tokens".
  `surface: ui` · `evidence: Sources/App/Views/AIProgressView.swift:12, Sources/App/Models/NoteProgress.swift` · `qa: NOTE-03`
- **AIE-033** When a progress bar is shown, it uses this Mac's measured reading speed for the model, saved on this Mac, and never moves backwards.
  `surface: ui` · `evidence: Sources/App/Models/AIRunStats.swift, Sources/App/Models/NoteProgress.swift:85` · `qa: NOTE-03`
- **AIE-034** When a multi-step run is in progress, the bar counts the step in progress as half done and is never full before the last step ends.
  `surface: ui` · `evidence: Sources/App/Models/AIRunSteps.swift` · `qa: NOTE-03`
- **AIE-035** When a note uses a structured format, the model can write only the format's exact section headings, in order.
  `surface: invariant` · `evidence: Sources/App/Services/Llama/NoteFormatGrammar.swift` · `qa: NOTE-04`
- **AIE-036** When the built-in engine loads, its window is a power of two of at least 8,192 sized to the prompt plus reply, never over the Mac's budget or the model's own maximum, and over that cap it fails rather than cutting text.
  `surface: invariant` · `evidence: Sources/App/Services/Llama/LlamaContextSize.swift, Sources/App/Services/Llama/LlamaEngine.swift` · `qa: NOTE-14`
- **AIE-037** When a fine-tuned adapter is paired with a different base model than it was made for, it is refused with a message.
  `surface: invariant` · `evidence: Sources/App/Services/Llama/FineTunedModel.swift` · `qa: SETTINGS-06`
- **AIE-038** When transcript text is given to the model, it is wrapped as reference material so instructions inside it are treated as data.
  `surface: invariant` · `evidence: Sources/App/Services/UntrustedText.swift` · `qa: NOTE-16`
- **AIE-040** When a model download is offered in Settings, the model's license link is visible there before the download is started.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:539, Sources/App/Views/ModelLicenseLink.swift` · `qa: SETTINGS-07`
- **AIE-041** When Settings shows the Language model card, it has no Engine menu while the built-in model is the only engine (the menu shows only when two engines can be chosen), and a separate Built-in model card lets the user pick the model, download or re-download it, and remove an unused downloaded one.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:483-546, Sources/App/Services/Integrations/AssistantBackend.swift` · `qa: SETTINGS-07`
- **AIE-042** When a fix-by-download runs, the overlay "Downloading the AI model…" with a progress bar appears.
  `surface: ui` · `evidence: Sources/App/Views/AIEngineProblemAlert.swift` · `qa: NOTE-09`

- **AIE-043** When a model is downloaded, the file is from a Hugging Face revision and SHA-256 pinned in the app.
  `surface: invariant` · `evidence: Sources/App/Services/Llama/LlamaModel.swift, scripts/verify-model-pins.sh` · `qa: SETTINGS-08`
- **AIE-044** When a different model is requested while a download is running, it is refused with "Another AI model is downloading. Try again when it finishes."
  `surface: ui` · `evidence: Sources/App/Services/Llama/LlamaModelDownloader.swift` · `qa: SETTINGS-08`
- **AIE-045** When Gemma 4 E2B is offered, it shows the Apache License 2.0 with no Acceptable Use Policy link or attribution.
  `surface: ui` · `evidence: Sources/App/Views/ModelLicenseLink.swift, Sources/App/Services/Llama/LlamaModel.swift` · `qa: SETTINGS-07`
- **AIE-046** When a background summary job is running and a note or question arrives, the summary yields and the note or question runs next.
  `surface: background` · `evidence: Sources/App/Services/InferenceQueue.swift` · `qa: NOTE-08`

## Patients (PAT)

- **PAT-001** When there are no patients, the sidebar shows a "No Patients Yet" message with a single Add Patient button.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift` · `qa: PATIENT-01`
- **PAT-002** When at least one patient exists, the Add Patient button sits in an always-visible footer at the foot of the sidebar (beside the search field, Report a Bug and Settings), so a narrow window never hides it.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift` · `qa: PATIENT-04`
- **PAT-003** When the therapist presses ⌘N or clicks Add Patient, a "New Patient" sheet asks for the patient's name, with Cancel and Add buttons.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift, Sources/App/Services/ShortcutCatalog.swift` · `qa: PATIENT-02`
- **PAT-004** While the new-patient name is blank or only spaces, the Add button stays disabled.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift` · `qa: PATIENT-02`
- **PAT-005** When a patient is added, the patient is selected straight away and their page opens.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift, Sources/App/Services/AppModel.swift` · `qa: PATIENT-03`
- **PAT-006** When a patient is renamed in the profile editor, extra spaces are trimmed and runs of whitespace collapse to one space, and a blank name is rejected.
  `surface: invariant` · `evidence: Sources/App/Models/Patient.swift, Sources/App/Views/PatientProfileEditor.swift` · `qa: PATIENT-05`
- **PAT-007** When the patient list is shown, patients are listed alphabetically (case-insensitive), each with round initials, the name, and either "N sessions · Mon d" (the date of the newest session; "1 session" when there is one) or "Added Mon yyyy" when there are no sessions.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift, Sources/App/Services/Store.swift` · `qa: PATIENT-04`
- **PAT-008** When text is typed in the search field, the sidebar patient list itself is not filtered; matching patients appear as the first group of the search results instead.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift` · `qa: SEARCH-02`
- **PAT-009** When a patient is right-clicked in the sidebar, an "Edit Profile…" item opens the profile editor.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift` · `qa: PATIENT-05`
- **PAT-010** When a patient's page is open, the header shows their name and a count reading "No sessions", "1 session" or "N sessions".
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: PATIENT-03`
- **PAT-011** When the therapist clicks the patient's name or the pencil on their page, the profile editor opens focused on the name.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift, Sources/App/Views/PatientProfileEditor.swift` · `qa: PATIENT-05`
- **PAT-012** When a profile row on the patient page is clicked, the editor opens with the cursor in the matching box (name, patient notes, clinical history, or the first medication).
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileEditor.swift, Sources/App/Views/PatientProfileCard.swift` · `qa: PATIENT-05`
- **PAT-013** When the patient page shows the profile card, only the filled-in rows appear, in the order Clinical history, Medications (only when the medications feature is in the build), Patient notes, each limited to three lines.
  `surface: ui` · `evidence: Sources/App/Models/Patient.swift, Sources/App/Views/PatientProfileCard.swift` · `qa: PATIENT-06`
- **PAT-014** When the profile editor is open, nothing is written until Save changes is pressed (or ⌘S); Save changes is disabled while the name is blank (which shows "A name is required.") and also while nothing has changed.
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileEditor.swift` · `qa: PATIENT-05`
- **PAT-015** When the therapist cancels or closes the profile editor with unsaved changes, it asks "Discard your changes?" with Discard Changes and Keep Editing, and the sheet cannot be dismissed by other means until they choose.
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileEditor.swift` · `qa: PATIENT-07`
- **PAT-016** When the therapist saves a profile, the name, patient notes and clinical history (and the medications, when that table is shown) are saved together in a single update.
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileEditor.swift, Sources/App/Services/AppModel.swift` · `qa: PATIENT-05`
- **PAT-017** When the medications feature is not in the build (it is a preview-tier feature), the medications table is hidden and any stored medications are kept untouched on save.
  `surface: invariant` · `evidence: Sources/App/Views/PatientProfileEditor.swift:105, Sources/App/Services/PatientMedicationsFeatureModule.swift` · `qa: PATIENT-12`
- **PAT-018** When medications are edited, the therapist can add rows (Add medication) with a name and a dose and remove rows (Remove medication), and the table reads "None recorded." when empty.
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileEditor.swift:244, Sources/App/Views/PatientProfileEditor.swift:251, Sources/App/Views/PatientProfileEditor.swift:266` · `qa: PATIENT-10`
- **PAT-046** When medications are saved, rows with both name and dose blank (after trimming) are dropped.
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileEditor.swift:58` · `qa: PATIENT-11`
- **PAT-047** When a patient has medications, the profile card lists each one with a name as "name dose", separated by commas, and leaves out any row with no name.
  `surface: ui` · `evidence: Sources/App/Models/Patient.swift:113` · `qa: PATIENT-11`
- **PAT-019** When "Include patient background" is on (the default), the clinical history, the therapist's patient notes and the current medications (those with a name) are supplied as a "Patient background" block when drafting notes, in session chat and in patient chat, and the block is left out when the patient has entered none.
  `surface: background` · `evidence: Sources/App/Models/Patient.swift, Sources/App/Services/Store.swift, Sources/App/Views/SettingsView.swift, Sources/App/Views/SessionDetailView.swift, Sources/App/Views/PatientChatView.swift` · `qa: NOTE-04`
- **PAT-020** When the patient notes caption says the notes are available to the AI and included in exports, the same notes are included in the records export as "Patient notes.txt" (only when non-empty) and in the assistant background.
  `surface: background` · `evidence: Sources/App/Views/PatientProfileEditor.swift, Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-06`
- **PAT-021** When the therapist chooses Delete patient… in the editor, a "Delete <name>?" confirmation sheet requires typing the patient's name (trimmed, case-insensitive) before the Delete Patient button is enabled.
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileEditor.swift` · `qa: PATIENT-08`
- **PAT-022** When a patient is deleted, their folder with every session, transcript, audio recording and note is permanently removed from disk, their chat threads, comments and notes are purged from the database, and the patient and their sessions are removed from the search index.
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Views/PatientProfileEditor.swift` · `qa: PATIENT-08`
- **PAT-023** When a patient is deleted and the database is open, a "pre-delete-patient" safety snapshot of the database is taken first, and if deletion fails an "Unable to delete patient" alert shows the reason.
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Views/PatientProfileEditor.swift` · `qa: PATIENT-08`
- **PAT-024** When a patient is stored on disk, their folder is named by the patient's UUID rather than the patient's name, with the details in patient.json inside it (sealed when encryption is on).
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift, README.md, docs/DATA-SAFETY.md` · `qa: BACKUP-05`
- **PAT-025** When an older install has patient folders named after the patient, they are migrated to UUID names after a JSON-only pre-image backup is kept; folders with an unreadable patient.json are skipped, a failed migration is rolled back, and a migration that cannot yet read sealed files waits and retries on the next open.
  `surface: background` · `evidence: Sources/App/Services/PatientFolderMigration.swift` · `qa: BACKUP-05`
- **PAT-026** When a patient folder's patient file cannot be read, the sidebar shows "1 record couldn't be read" (or "N records couldn't be read") as a dismissible notice, and the folder is left untouched.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift, Sources/App/Views/DamagedRecordsNotice.swift, Sources/App/Services/AppModel.swift` · `qa: BACKUP-07`
- **PAT-027** When the patient's records are exported, a zip is built in the background containing a "<Name> records" folder with "Read me.txt", the patient notes, and a "Sessions" folder with one folder per session (oldest first, named by date and time) holding Transcript.txt and a "Note - <format>.txt" per saved format (Summary.txt only when there are no per-format notes); comments and psychotherapy notes are left out.
  `surface: background` · `evidence: Sources/App/Services/PatientArchive.swift, Sources/App/Views/PatientDetailView.swift` · `qa: EXPORT-09`
- **PAT-028** When a patient has no sessions, "Ask about this patient" and "Export all records" are disabled, and Export is also disabled while another export is running.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: PATIENT-07`
- **PAT-029** When a patient needs summaries, the patient page shows a status row reading "Summaries: all N ready" or "Summaries: R of N ready", with " · preparing" or a "paused" reason (locked, recording, transcribing, AI busy, Low Power Mode, battery, or after a problem) plus Pause, Resume and "Prepare now"; the row is hidden when no summaries are needed, and opening the page reprioritises that patient's summary jobs.
  `surface: background` · `evidence: Sources/App/Views/SummaryStatusRow.swift, Sources/App/Services/Digest/DigestSchedulePolicy.swift, Sources/App/Views/PatientDetailView.swift` · `qa: DIGEST-01`
- **PAT-030** When the app is locked or a patient appears on a system surface, patients are named by dotted initials ("J.D."; "?" for a blank name) and no deep link into the patient is offered while locked.
  `surface: invariant` · `evidence: Sources/App/Services/PatientLabel.swift, Sources/App/Services/SessionQueries.swift` · `qa: NOTIFY-08`
- **PAT-031** When App Intents (a developer-build-only feature) ask for today's sessions, they list sessions across all patients, newest first, labelled by initials, and answer "Aletheia is locked. Unlock it first." while locked.
  `surface: background` · `evidence: Sources/App/Services/SessionQueries.swift, Sources/App/Intents, Sources/App/Services/PatientLabel.swift` · `qa: SESSION-08`
- **PAT-032** When a patient name is typed into any patient text field, macOS Writing Tools is kept off for that text.
  `surface: invariant` · `evidence: CLAUDE.md, Sources/App/Views/Theme` · `qa: LOCK-08`
- **PAT-033** When Return is pressed in the New Patient field with a blank name, no patient is created, matching the disabled Add button.
  `surface: ui` · `evidence: Sources/App/Views/PatientsListView.swift:204-212, Sources/App/Services/AppModel.swift:530-531` · `qa: PATIENT-02`
- **PAT-034** When a patient is added, the name is stored exactly as typed; trimming and whitespace collapsing happen only when the profile editor renames.
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift, Sources/App/Models/Patient.swift` · `qa: PATIENT-03`
- **PAT-035** When a patient has no profile details, the profile card reads "Nothing recorded yet. Edit to add clinical history or notes; both are available to the AI." with an Edit button.
  `surface: ui` · `evidence: Sources/App/Views/PatientProfileCard.swift` · `qa: PATIENT-06`
- **PAT-036** When the records export is built, clinical history and medications are not included; only the patient notes are.
  `surface: background` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-06`
- **PAT-037** When a patient is deleted, an audit entry of kind "recordDeleted" (detail "patient") is written, and the patient list and Spotlight index are refreshed.
  `surface: background` · `evidence: Sources/App/Services/AppModel.swift` · `qa: SECURITY-04`
- **PAT-038** When the selected patient disappears (for example after deletion), the first remaining patient is selected, or the search home is shown when none is left.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift` · `qa: PATIENT-08`
- **PAT-039** When the patient folder upgrade has failed, adding or saving patients is refused with "The patient folder upgrade must finish before records can be changed. Reopen Aletheia after resolving the folder issue."
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/PatientFolderMigration.swift` · `qa: BACKUP-06`
- **PAT-040** When a damaged-record notice is dismissed, the dismissal is remembered in settings; and a patient file that is sealed while the folder is locked is not reported as damaged.
  `surface: background` · `evidence: Sources/App/Services/AppSettings.swift, Sources/App/Services/AppModel.swift` · `qa: BACKUP-07`
- **PAT-041** When a session has nothing in it (no transcript, notes or comments), it is left out of the records export and the count is stated in the Read me.
  `surface: background` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-06`
- **PAT-042** When a transcript exists but cannot be read, the records export fails instead of silently skipping that session.
  `surface: background` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-09`
- **PAT-043** When Export all records is chosen, a save panel suggests "<Name> Records.zip", the work runs in the background, and an audit entry "recordExported" ("Patient records, zip of N sessions") is written.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: EXPORT-09`
- **PAT-044** When Spotlight indexing is switched on (a preview-tier, opt-in feature), patients and sessions are indexed with the initials title and "Therapy patient in Aletheia." (sessions: "<initials> — <long date>"), with no transcript content; the index is cleared while locked and a tap while locked does nothing.
  `surface: background` · `evidence: Sources/App/Services/Spotlight, Sources/App/Services/PatientLabel.swift` · `qa: SEARCH-12`
- **PAT-045** When "Include patient background" is switched off in Settings, no patient background is sent to note drafting, session chat or patient chat.
  `surface: background` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Views/SessionDetailView.swift, Sources/App/Views/PatientChatView.swift` · `qa: NOTE-04`

## Sessions (SES)

- **SES-001** When the therapist presses New session on a patient's page, and the disk is not known to be unencrypted, a session dated now is created, listed and opened; a further press within 10 seconds of the last one is ignored (file imports are not debounced).
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift, Sources/App/Services/Store.swift, Sources/App/Services/AppModel.swift` · `qa: SESSION-02`
- **SES-002** When a patient has no sessions, the session list shows "No Sessions Yet" with a New session button, and the right pane says "Select a Session".
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: SESSION-01`
- **SES-003** When a new session is created, its folder is named by its date (yyyy-MM-dd) followed by "_Session", with "_Session-2", "_Session-3" and so on for further sessions on the same day.
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift` · `qa: BUILD-10`
- **SES-004** When a session is created, session.json (plaintext) holds a UUID and the date, assigned once and never derived from the folder name; a folder without one gets an id minted and saved.
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/CommentStore.swift` · `qa: BUILD-10`
- **SES-005** When a session folder is renamed or moved, its comments, notes and chat stay attached to it.
  `surface: invariant` · `evidence: Sources/App/Services/CommentStore.swift, Sources/App/Services/Store.swift` · `qa: BUILD-10`
- **SES-006** When a session has content, its folder holds session.json, mic.caf and call.caf for audio, transcript.txt, a note.<format>.txt with a note.<format>.meta.json per generated format, a legacy summary.txt, and digest.json for the summary.
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift` · `qa: BUILD-10`
- **SES-007** When the session list is shown, sessions appear newest first (sessions created at the same time keep their creation order), each with the medium date, then the time and "Audio" when call.caf or mic.caf exists.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift, Sources/App/Services/Store.swift` · `qa: SESSION-02`
- **SES-008** When a session has a transcript (transcript.txt) or a saved summary (summary.txt), its row shows a "Transcript" or "Note" chip, and "Recording" while it is being recorded.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift:447, Sources/App/Views/PatientDetailView.swift:448, Sources/App/Views/PatientDetailView.swift:449, Sources/App/Models/SessionRecord.swift` · `qa: SESSION-03`
- **SES-009** When a session is being recorded, transcribed or waiting to be transcribed, its row says "Recording in progress", "Transcribing…" or "Waiting to transcribe" with a spinner while transcribing.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift:420, Sources/App/Views/PatientDetailView.swift:421, Sources/App/Views/PatientDetailView.swift:422` · `qa: SESSION-03`
- **SES-010** When a transcription finishes for any of the patient's sessions, the list refreshes so the chips and recording state update even if that session is not open.
  `surface: background` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: SESSION-03`
- **SES-011** When the therapist clicks the empty space of the session list, the open session stays open.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: SESSION-02`
- **SES-012** When the open session has unsaved transcript edits and another session is chosen, a "Save your transcript edits?" prompt ("This session's transcript has changes you haven't saved.") offers Save, Discard Edits or Cancel before switching.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift, Sources/App/Views/UnsavedTranscriptGuard.swift` · `qa: TRANSCRIBE-11`
- **SES-013** When a session disappears from the listing, the selection is cleared instead of pointing at a missing session.
  `surface: invariant` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: SESSION-03`
- **SES-014** When a session folder's session file cannot be read, the page shows "1 session couldn't be read" (or "N sessions couldn't be read") as a dismissible notice, and the folder is never rewritten nor given a new identity.
  `surface: invariant` · `evidence: Sources/App/Views/PatientDetailView.swift, Sources/App/Services/Store.swift` · `qa: BACKUP-07`
- **SES-015** When the disk is known to be unencrypted, New session is refused with a "Turn on FileVault" alert; when disk encryption cannot be confirmed, a "Couldn't confirm disk encryption" warning shows once per launch and the session is created. The app lock plays no part in this check.
  `surface: ui` · `evidence: Sources/App/Services/AppModel.swift, Sources/App/Services/DiskEncryption.swift, Sources/App/Views/PatientDetailView.swift` · `qa: SESSION-02`
- **SES-016** When a transcript is saved after an edit, the session's text is queued for the search index, and generated notes made from the earlier text show an "Outdated: the transcript has changed since this note was generated." banner with Regenerate (computed by comparing a stored transcript fingerprint; the therapist's own notes are never flagged).
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Views/SessionDetailView.swift, Sources/App/Views/OutdatedNoteBanner.swift` · `qa: NOTE-12`
- **SES-017** When a session is opened from search, from Spotlight (preview-tier) or from a link, the app selects the patient, then the session, on the requested tab (transcript, a note format, or My Notes); App Intents (developer builds only) open patients the same way.
  `surface: ui` · `evidence: Sources/App/Services/AppNavigator.swift, Sources/App/Views/PatientDetailView.swift, Sources/App/Views/RootView.swift` · `qa: SEARCH-06`
- **SES-018** When a session is opened from a link by folder name or by id, whichever the link carries is matched against the patient's sessions, and nothing happens if the session is not found.
  `surface: background` · `evidence: Sources/App/Services/AppNavigator.swift, Sources/App/Views/PatientDetailView.swift` · `qa: SEARCH-06`
- **SES-019** When a search result opens a session, only that session opens at the match, and a session picked from the list afterwards does not.
  `surface: invariant` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: SEARCH-06`
- **SES-020** When the menu-bar "Open Aletheia", "Show this session" (which opens the recording's patient), Unlock or start-recording actions are used, or Doctor's update check runs, the main window is unhidden, activated and reopened or raised; a successful unlock otherwise only hands focus to a visible window.
  `surface: background` · `evidence: Sources/App/Services/MainWindow.swift, Sources/App/Services/AppLock.swift` · `qa: MENUBAR-03`
- **SES-021** When the set-aside recordings warning strip's Review in Settings… is chosen, Settings opens on the Set-aside recordings page.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift:223, Sources/App/Services/AppNavigator.swift:111, Sources/App/Views/SettingsView.swift:176` · `qa: SESSION-04`
- **SES-036** When Set up… is chosen in the Doctor, Settings opens on the General page with the Setup Assistant shown.
  `surface: ui` · `evidence: Sources/App/Services/Features/Doctor/DoctorModel.swift:70, Sources/App/Views/SettingsView.swift:158` · `qa: SECURITY-07`
- **SES-022** When the therapist chooses Schedule Next… (a developer-build-only feature), a "Schedule next session" sheet offers quick picks "Next week", "In 2 weeks" and "In 4 weeks" that keep the chosen time of day, and Date and Time pickers.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift, Sources/App/Views/SessionDetailView.swift` · `qa: SESSION-06`
- **SES-023** When the schedule sheet is shown, the session length can be 30, 45, 50, 60 or 90 minutes (default 50), and a different current length is added to the choices.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **SES-024** When the next session is scheduled, the calendar event is titled "Therapy session" with the note "Therapy session.", carries a start, an end and an optional repeat (Never, weekly, every 2 or 4 weeks, monthly), never includes the patient's name, and an .ics file is saved only when "Save an .ics file" is ticked.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift, Sources/App/Views/SessionDetailView.swift` · `qa: SESSION-06`
- **SES-025** When the therapist exports a single session (offered when there is a transcript or summary), it is saved as PDF, Word or Markdown with the patient's name, the date, a Summary and a Transcript section, each omitted when empty, and an audit entry is written.
  `surface: ui` · `evidence: Sources/App/Services/MarkdownExporter.swift, Sources/App/Services/Store.swift, Sources/App/Views/SessionDetailView.swift` · `qa: EXPORT-11`
- **SES-026** When the Mac is asked a question across a patient's sessions, each session gets a short citation tag (S1, S2…) newest first, with same-day sessions sharing one tag.
  `surface: background` · `evidence: Sources/App/Services/Store.swift` · `qa: CHAT-12`
- **SES-027** When a session's transcript exists but cannot be read, the assistant context marks it as "[transcript could not be read]" instead of treating it as never discussed.
  `surface: background` · `evidence: Sources/App/Services/Store.swift` · `qa: CHAT-12`
- **SES-028** When a patient's notes, comments and generated notes are sent to the assistant, no more than 3,000 characters per session are added beyond the transcript, filled newest sessions first up to a third of the available room.
  `surface: background` · `evidence: Sources/App/Services/Store.swift` · `qa: CHAT-12`
- **SES-029** When folder encryption is on (it can only be switched on in developer builds), patient.json, transcripts, notes and other record files are sealed at rest and read back through the same protection; session.json, folder names, dates and the database file are not fully encrypted.
  `surface: invariant` · `evidence: Sources/App/Services/Store.swift, docs/ENCRYPTION.md` · `qa: ENCRYPT-05`
- **SES-030** When the README says there is no delete-session action, the app offers no way to delete a single session; deletion happens only by deleting the patient.
  `surface: invariant` · `evidence: README.md, Sources/App/Views/PatientDetailView.swift` · `qa: SESSION-02`
- **SES-031** When Save is chosen in the unsaved-edits prompt and saving fails, the pending switch to the other session is dropped and the edits stay.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: TRANSCRIBE-11`
- **SES-032** When a session is exported and has neither transcript nor summary, the Markdown reads "_No transcript or summary recorded for this session yet._".
  `surface: ui` · `evidence: Sources/App/Services/MarkdownExporter.swift` · `qa: EXPORT-11`
- **SES-033** When Remind Me is chosen (a developer-build-only feature), Tomorrow, In 3 days or Next week adds a reminder titled "Follow up (Aletheia)", noting "Re: therapy session on <long date>.", due at 9:00 AM with an alarm.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/Reminders` · `qa: SESSION-07`
- **SES-034** When the schedule sheet finishes, it confirms with `Added “Therapy session” to your Calendar.` (adding " and saved .ics file" when saved), or "Saved .ics file. Could not add to Calendar: …"; when Calendar access is denied it says Aletheia can't add Calendar events and points to System Settings › Privacy & Security › Calendars.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **SES-035** When refreshing a patient's sessions fails, an alert titled "Something went wrong" shows the error.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: SESSION-03`
- **SES-037** When the therapist presses New session while the disk is known to be unencrypted, no session is created and the "Turn on FileVault" alert is shown.
  `surface: ui` · `evidence: Sources/App/Services/AppModel.swift:548, Sources/App/Services/DiskEncryption.swift:47` · `qa: SESSION-09`
- **SES-038** When sessions are created by file import, the 10-second debounce on New session does not apply.
  `surface: ui` · `evidence: not yet traced to source` · `qa: SESSION-02`

## Search (SRC)

- **SRC-001** When the therapist presses ⌘F anywhere in the window, including while the cursor is in a transcript or note, the global search field takes focus.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchField.swift, Sources/App/Services/ShortcutCatalog.swift` · `qa: SEARCH-01`
- **SRC-002** When the therapist presses ⌥⌘F in a transcript or note, that text's own find bar opens instead of the global search.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchField.swift, Sources/App/Services/ShortcutCatalog.swift` · `qa: SEARCH-01`
- **SRC-003** When the sidebar is visible, the sidebar search field sits at its foot with the prompt "Search all patients", and it searches every patient, not the open session.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchField.swift, Sources/App/Views/PatientsListView.swift` · `qa: SEARCH-01`
- **SRC-004** When no patient is open, the home screen shows a large search field reading "Search all patients, sessions and notes" with the ⌘F hint while it is unfocused, focused automatically unless the cursor is already in another text field.
  `surface: ui` · `evidence: Sources/App/Views/SearchHomeView.swift, Sources/App/Views/GlobalSearchField.swift` · `qa: SEARCH-01`
- **SRC-005** When the sidebar is hidden and the home search field is empty, a button offers "or show the sidebar to choose a patient".
  `surface: ui` · `evidence: Sources/App/Views/SearchHomeView.swift` · `qa: SEARCH-01`
- **SRC-006** When text is typed in the sidebar search field or the home search field, both show the same query and the same results, and the first letter typed keeps the cursor in the field.
  `surface: ui` · `evidence: Sources/App/Views/SearchHomeView.swift, Sources/App/Services/Search/GlobalSearchModel.swift` · `qa: SEARCH-02`
- **SRC-007** When a query is present, results show over the detail pane, and when it is cleared the previous screen returns.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchResultsView.swift, Sources/App/Views/SearchHomeView.swift` · `qa: SEARCH-02`
- **SRC-008** When the therapist types in the sidebar or home search field, the search runs after a brief pause once typing stops, off the main thread, and a newer query cancels the older one.
  `surface: background` · `evidence: Sources/App/Services/Search/GlobalSearchModel.swift, Sources/App/Views/RootView.swift` · `qa: SEARCH-02`
- **SRC-009** When results are shown, they are grouped as Patients, Sessions, Psychotherapy notes, Progress notes, Comments and Transcripts, in that order, with empty groups left out and each group's match count in a chip beside its heading.
  `surface: ui` · `evidence: Sources/App/Models/SearchHit.swift, Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-03`
- **SRC-010** When a group has more than five matches, only the best five show and a "Show 25 more of N" row (or "Show N more" for the last few) reveals further matches, up to 200 per group, after which a note reads "Showing the first 200 of N. Add a word to narrow the search."
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearch.swift, Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-04`
- **SRC-011** When a result row is shown, it reads "Patient, Mon d, yyyy" followed by " (SOAP)" or the other note format for a note, or " at m:ss" for a comment tied to a moment, with a one-line snippet where the matching words are highlighted.
  `surface: ui` · `evidence: Sources/App/Models/SearchHit.swift, Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-03`
- **SRC-012** When a patient matches in the sidebar or home search, the row shows their session count ("1 session" or "N sessions") as the snippet.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchEngine.swift` · `qa: SEARCH-03`
- **SRC-013** When the therapist presses the up or down arrow in the search field, the selection moves through the results and the list scrolls to keep it visible.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchField.swift, Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-05`
- **SRC-014** When the therapist presses Return with a result selected, that result opens; on a "Show more" row it reveals more results instead.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchField.swift, Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-05`
- **SRC-015** When the therapist clicks a result, it is selected and opened.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-05`
- **SRC-016** When the therapist presses Esc with a query, the query clears; with an empty query, the field gives up focus.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchField.swift` · `qa: SEARCH-05`
- **SRC-017** When a query is present, an x button labelled "Clear search" appears in the field and clears the query.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchField.swift` · `qa: SEARCH-05`
- **SRC-018** When nothing matches, the results show "No results for “query”", or "No results yet for “query”" while the index is still incomplete, instead of an empty list.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-08`
- **SRC-019** When results change, VoiceOver is told the number of results and groups, and whether they may be incomplete, once per change.
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchResultsView.swift, Sources/App/Services/Search/GlobalSearchModel.swift` · `qa: SEARCH-08`
- **SRC-020** When a result is a patient, opening it selects that patient; a session or anything inside one opens that session on the tab (transcript, a note format, the psychotherapy note, or a comment) where the match is.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchModel.swift, Sources/App/Services/AppNavigator.swift` · `qa: SEARCH-06`
- **SRC-021** When a transcript or note result is opened, the session scrolls to the matching line or paragraph and flashes the matching word, once per opening.
  `surface: ui` · `evidence: Sources/App/Services/Search/SearchMatchFocus.swift, Sources/App/Services/Search/GlobalSearchModel.swift` · `qa: SEARCH-06`
- **SRC-022** When the line a transcript hit pointed at has since been edited, the flash falls back to the first match anywhere in the transcript.
  `surface: ui` · `evidence: Sources/App/Services/Search/SearchMatchFocus.swift` · `qa: SEARCH-06`
- **SRC-023** When a comment result is opened, the comment's card is focused in the rail and its passage in the transcript is scrolled to and flashed.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchModel.swift, Sources/App/Views/CommentsRailView.swift` · `qa: SEARCH-06`
- **SRC-024** When a query is typed in the sidebar or home search field, patients are found by name, sessions by date, and notes, comments and transcripts by their text, in one query.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchEngine.swift, Sources/App/Views/GlobalSearchField.swift` · `qa: SEARCH-03`
- **SRC-025** When several words are typed in the sidebar or home search field, up to the first 8 distinct words are used and each must match (in a name, a date or the text, with at least one in the text for note, comment and transcript results); no word is ignored for being short or common.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchQuery.swift` · `qa: SEARCH-06`
- **SRC-026** When a query has more than eight different words, only the first eight are used and repeated words count once.
  `surface: invariant` · `evidence: Sources/App/Services/Search/GlobalSearchQuery.swift` · `qa: SEARCH-06`
- **SRC-027** When a patient's name and a topic are typed together in the sidebar or home search field, the notes, comments and transcripts of that patient's sessions that mention the topic are found, and a word of the date narrows them to sessions on that date.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchQuery.swift, Sources/App/Services/Search/GlobalSearchEngine.swift` · `qa: SEARCH-14`
- **SRC-028** When a word is typed in the sidebar or home search field, other forms of it match because words are matched by their stem, except common words, which match whole.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchQuery.swift, Sources/App/Services/Search/SearchIndex.swift` · `qa: SEARCH-07`
- **SRC-029** When a word of two or more characters is typed in the sidebar or home search field, results keep up with typing, so "thera" finds "therapy"; a single letter or digit matches only as a whole word; a patient's name matches anywhere inside it, so "ann" finds "Joanne".
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchQuery.swift, Sources/App/Services/Search/GlobalSearchEngine.swift` · `qa: SEARCH-07`
- **SRC-030** When a query is typed in capitals or without accents, it still matches text regardless of case and diacritics.
  `surface: ui` · `evidence: Sources/App/Services/TextSearch.swift, Sources/App/Services/Search/GlobalSearchQuery.swift` · `qa: SEARCH-13`
- **SRC-031** When results are ranked inside a group, the best match comes first by relevance, then by more matching passages, then by newer session; patients are listed alphabetically and sessions newest first.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearch.swift, Sources/App/Services/Search/GlobalSearchEngine.swift` · `qa: SEARCH-07`
- **SRC-032** When the README lists typo tolerance, sound-alike names, quoted phrases, "wor*" prefixes and date phrases, those apply to the assistant's retrieval over a patient's history, not to the sidebar or home search field, which has no typo tolerance, sound-alike names or quoted phrases.
  `surface: invariant` · `evidence: README.md:97-102, Sources/App/Services/Search/SessionSearch.swift, Sources/App/Services/Search/GlobalSearchQuery.swift` · `qa: CHAT-12`
- **SRC-033** When the assistant looks up a patient's history, a misspelled word, a similar-sounding name, a quoted phrase, a word prefix ending in * and a date phrase such as a month all narrow or widen what is found.
  `surface: background` · `evidence: Sources/App/Services/Search/SessionSearch.swift, README.md:97-102` · `qa: CHAT-12`
- **SRC-034** When an index exists, the sidebar and home search read original text only for the results they show, so cost stays about the same for 10 sessions as for 1,000.
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/Search/GlobalSearchEngine.swift` · `qa: SEARCH-10`
- **SRC-035** When the index is missing or cannot be read, the sidebar and home search fall back to scanning every file with plain substring matching (no stems or date words) and no "incomplete" line, stopping early if the query is superseded.
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/TextSearch.swift` · `qa: SEARCH-10`
- **SRC-036** When the index is still being checked or built, or a transcript has changed since it was indexed, a line above the results says "Checking the search index; results may be incomplete." or "Indexing N sessions; results may be incomplete." ("Indexing 1 session" for one).
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearch.swift, Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-09`
- **SRC-037** When sessions finish indexing, an open search runs again by itself and its results fill in and the indexing count counts down.
  `surface: background` · `evidence: Sources/App/Services/Search/SearchIndexSweep.swift, Sources/App/Views/RootView.swift` · `qa: SEARCH-09`
- **SRC-038** When the app launches, unlocks, the data folder changes or the index starts over, a background sweep indexes sessions whose transcripts are new or changed, stale ones first and newest first.
  `surface: background` · `evidence: Sources/App/Services/Search/SearchIndexSweep.swift, Sources/App/Services/AppModel.swift` · `qa: SEARCH-09`
- **SRC-039** When a recording, a transcription or the AI model is running, the background indexing pauses and resumes afterwards.
  `surface: background` · `evidence: Sources/App/Services/Search/SearchIndexSweep.swift` · `qa: SEARCH-09`
- **SRC-040** When a transcript, note or comment is saved, its text is queued for the index shortly after (bursts of saves are combined), and results stay marked incomplete until it is in.
  `surface: background` · `evidence: Sources/App/Services/Search/SearchIndexSweep.swift, Sources/App/Services/Store.swift` · `qa: SEARCH-09`
- **SRC-041** When a patient is deleted, its sessions are removed from the index at once and again after any queued saves finish, and sessions missing from a complete folder listing are dropped only after every session was read.
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/Search/SearchIndexSweep.swift` · `qa: SEARCH-09`
- **SRC-042** When the index file is damaged, from another version, or found corrupt while in use, it is thrown away and rebuilt from the transcripts.
  `surface: background` · `evidence: Sources/App/Services/Search/SearchIndex.swift, Sources/App/Services/AppModel.swift` · `qa: SEARCH-10`
- **SRC-043** When the search index is stored, it lives in the data folder as its own file, holds an unencrypted copy of the searchable words (stemmed, with patient, session and date), is excluded from Time Machine and zeroes freed pages.
  `surface: invariant` · `evidence: Sources/App/Services/Search/SearchIndex.swift, Sources/App/Services/BackupExclusion.swift` · `qa: BUILD-10`
- **SRC-044** When the app locks, the index connection is closed but the file stays, and search returns nothing until unlock, with no fallback scan of the files.
  `surface: invariant` · `evidence: Sources/App/Services/AppLock.swift, Sources/App/Services/Search/SearchIndex.swift` · `qa: SEARCH-11`
- **SRC-045** When the app quits with encryption on, the index file is deleted; otherwise it is only closed.
  `surface: invariant` · `evidence: Sources/App/Services/AppModel.swift` · `qa: ENCRYPT-09`
- **SRC-046** When the shortcuts window lists search, it shows "Search everything" as ⌘F, "Find in this transcript or note" as ⌥⌘F and "Close a sheet or search" as Esc.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift` · `qa: SEARCH-01`
- **SRC-047** When anything is searched, the query, results and index never leave the Mac.
  `surface: invariant` · `evidence: CLAUDE.md, Sources/App/Services/Search/SearchIndex.swift` · `qa: BUILD-07`
- **SRC-048** When a note's legacy summary exists with no per-format notes, the sidebar and home search find it and show it as the "Summary" note.
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/Search/GlobalSearchEngine.swift` · `qa: SEARCH-03`
- **SRC-049** When results are shown, a footer lists the keys for move, open (only when there are rows) and clear, with the total number of matches ("1 result", "N results").
  `surface: ui` · `evidence: Sources/App/Views/GlobalSearchResultsView.swift` · `qa: SEARCH-05`
- **SRC-050** When a result is opened, the search clears and the field gives up focus.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift` · `qa: SEARCH-05`
- **SRC-051** When a query is typed, the sidebar patient list is not filtered by it; matches show only in the results.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift, Sources/App/Views/PatientsListView.swift` · `qa: SEARCH-02`
- **SRC-052** When results cover the detail pane of an open patient, the pane underneath is kept, so unsaved edits survive the search.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift` · `qa: SEARCH-02`
- **SRC-053** When a session is searched in the sidebar or home search, it is found by its date words (day, month name, year) and only together with its patient name or a date word, so a patient's name alone returns the patient, not their sessions.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchEngine.swift, Sources/App/Services/Search/GlobalSearchQuery.swift` · `qa: SEARCH-06`
- **SRC-054** When "may", "mar" or "march" is typed, it counts as a date word only next to a number that also matches that date (for example "march 2026"); otherwise it is an ordinary word.
  `surface: ui` · `evidence: Sources/App/Services/Search/GlobalSearchQuery.swift` · `qa: SEARCH-06`
- **SRC-055** When folder encryption is locked, the index file is deleted, and when the app launches with encryption on and locked, any leftover index file is deleted.
  `surface: invariant` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift, Sources/App/Services/AppModel.swift` · `qa: SEARCH-11`
- **SRC-056** When folder encryption is turned on or off, the index file is deleted and rebuilt.
  `surface: invariant` · `evidence: Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: ENCRYPT-09`
- **SRC-057** When the app or folder is unlocked, the index is reopened and the background sweep runs again.
  `surface: background` · `evidence: Sources/App/Services/AppLock.swift, Sources/App/Services/Crypto/EncryptionManager.swift` · `qa: SEARCH-11`
- **SRC-058** When a patient is deleted, their documents are removed from the search index, so no later search returns them.
  `surface: background` · `evidence: Sources/App/Services/Store.swift:362, Sources/App/Services/AppModel.swift:586` · `qa: SEARCH-15`

## Comments (CMT)

- **CMT-001** When the therapist selects non-blank text in a saved, readable transcript, a floating Comment button appears just above the first line of the selection, or below it when there is no room, as long as that line is on screen and the pane is wide enough.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: COMMENT-01`
- **CMT-002** When the transcript has unsaved edits, is being composed on, or cannot be read, the Comment button does not appear.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: COMMENT-01`
- **CMT-003** When the therapist presses ⌥⌘M or the Comment button, a composer card titled "Comment on selected text" opens under the passage showing the quoted text.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: COMMENT-02`
- **CMT-004** When the composer is open, the time stamp of the passage's line is shown if one can be found, and the comment is pinned to the exact occurrence selected, even when the same words repeat.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/CommentStore.swift` · `qa: COMMENT-02`
- **CMT-005** When the comment text is blank, Save comment is disabled and does nothing.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: COMMENT-02`
- **CMT-006** When a comment fails to save, a save-failure notice about the comment appears and the composer stays open with the typed text kept.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/AppModel.swift` · `qa: COMMENT-03`
- **CMT-007** When a comment is saved, the surrounding whitespace is trimmed, the composer closes, its card appears in the rail and is brought into focus, and its passage flashes.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: COMMENT-03`
- **CMT-008** When a session has no comments at all (open or resolved), the comments pane is not shown and the transcript takes the full width.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptSplitView.swift, Sources/App/Services/TranscriptSplit.swift` · `qa: COMMENT-01`
- **CMT-009** When a session has comments, a draggable divider sets the split between transcript and comments, and the split is remembered.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptSplitView.swift, Sources/App/Services/TranscriptSplit.swift` · `qa: COMMENT-05`
- **CMT-010** When the comments side is collapsed, its strip shows the count of open comments and a "Show comments" arrow, and focusing a comment reopens it if both sides fit.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptSplitView.swift` · `qa: COMMENT-05`
- **CMT-011** When the rail is shown, open comments are cards ordered by where they fall in the session, with comments that have no time position after them in creation order.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift` · `qa: COMMENT-03`
- **CMT-012** When a card is shown, it displays the time chip (if the comment has a time position), the quoted passage in quotes (up to three lines, if there is one) and the comment text, and the header shows the count of open comments unless it is zero.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift` · `qa: COMMENT-03`
- **CMT-013** When a comment's passage is highlighted in the transcript and the therapist clicks it, the matching card is focused and scrolled into view.
  `surface: ui` · `evidence: Sources/App/Views/TranscriptTextView.swift, Sources/App/Views/CommentsRailView.swift` · `qa: COMMENT-04`
- **CMT-014** When a card is clicked, its passage in the transcript is scrolled to and flashed, every time, even when that card is already focused, unless the passage can no longer be found.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift, Sources/App/Services/TranscriptHighlighter.swift` · `qa: COMMENT-04`
- **CMT-015** When Edit is pressed on a card, the body becomes an editor, Save (Return) is disabled for blank or unchanged text and trims what it stores, nothing is stored until Save, and Cancel (Esc) discards the draft.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift` · `qa: COMMENT-06`
- **CMT-016** When Resolve is pressed, the comment moves into a collapsed "Resolved (N)" section, newest update first and dimmed.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift` · `qa: COMMENT-06`
- **CMT-017** When a resolved comment is brought into focus, or the rail appears with one focused, the Resolved section opens to show it.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift` · `qa: COMMENT-06`
- **CMT-018** When Delete is pressed on a card, the comment is removed at once, with no confirmation, from the database and from search.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift, Sources/App/Services/CommentStore.swift` · `qa: COMMENT-07`
- **CMT-019** When a transcript is edited so a comment's passage no longer exists, the comment is kept, stays in the rail with its quote and a note "Original passage not found", and clicking it does not scroll.
  `surface: invariant` · `evidence: Sources/App/Views/CommentsRailView.swift, Sources/App/Services/TranscriptHighlighter.swift` · `qa: COMMENT-07`
- **CMT-020** When a comment or note is saved, edited, resolved or deleted, the search index for that session is refreshed in the background, with bursts of changes combined.
  `surface: background` · `evidence: Sources/App/Services/CommentStore.swift, Sources/App/Services/Store.swift` · `qa: COMMENT-07`
- **CMT-021** When a search is made in the sidebar or home search field, comments (resolved ones too) are found by what the therapist wrote and also by the quoted passage, and a comment hit shows the comment text if it matches, otherwise the quote.
  `surface: ui` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/Search/GlobalSearchEngine.swift` · `qa: SEARCH-03`
- **CMT-022** When the assistant is asked about a patient, each session's material gives the therapist's own session notes and comments, labelled as her words, before the generated progress notes, within a per-session length cap; for a single session, her notes and comments are included alongside the transcript.
  `surface: background` · `evidence: Sources/App/Services/Store.swift, Sources/App/Services/Prompts.swift:350` · `qa: NOTE-04`
- **CMT-023** When comments are stored, they sit in the local database inside the data folder, sealed at rest like other patient data, and are keyed by the session's identity.
  `surface: invariant` · `evidence: Sources/App/Services/CommentStore.swift, Sources/App/Services/Repositories/AnnotationRepository.swift` · `qa: ENCRYPT-05`
- **CMT-024** When a stored comment cannot be opened, it is left out of the rail and listed among the unreadable records; when a note cannot be decoded, it reads as empty and is flagged as damaged, and saving over it is refused.
  `surface: invariant` · `evidence: Sources/App/Services/CommentStore.swift, Sources/App/Services/Repositories/AnnotationRepository.swift, Sources/App/Views/PatientsListView.swift:20` · `qa: BACKUP-07`
- **CMT-025** When folder encryption is turned on or off, existing comments are re-sealed in place, and a row that cannot be converted is left untouched and reported as a failure for the database.
  `surface: background` · `evidence: Sources/App/Services/CommentStore.swift:259, Sources/App/Services/Crypto/DataMigrator.swift:66` · `qa: ENCRYPT-05`
- **CMT-026** When a patient is deleted, all of their comments, notes and chats are purged from the database.
  `surface: background` · `evidence: Sources/App/Services/CommentStore.swift, Sources/App/Services/Store.swift` · `qa: PATIENT-08`
- **CMT-027** When the records are exported, comments are written to a plain-text Comments file per session.
  `surface: background` · `evidence: Sources/App/Services/PatientArchive.swift:81` · `qa: EXPORT-07`
- **CMT-028** When the comment text is non-blank but the quote is empty, Save comment does nothing; and ⌘Return saves a comment.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Services/ShortcutCatalog.swift` · `qa: COMMENT-02`
- **CMT-029** When a side is dragged below its minimum width by a margin, it folds into a narrow strip with an arrow that reopens it, resetting the split to its default; the folded state is not remembered across sessions.
  `surface: ui` · `evidence: Sources/App/Services/TranscriptSplit.swift, Sources/App/Views/TranscriptSplitView.swift` · `qa: COMMENT-05`
- **CMT-030** When Resolve is pressed, the comment loses its transcript highlight, and Reopen brings it and the highlight back.
  `surface: ui` · `evidence: Sources/App/Views/CommentsRailView.swift, Sources/App/Services/TranscriptHighlighter.swift` · `qa: COMMENT-06`
- **CMT-031** When a progress note is drafted, comments are included only if "Include comments in drafts" is on (it is on by default), although the composer says "Comments are included when the progress note is drafted."
  `surface: background` · `evidence: Sources/App/Views/SessionDetailView.swift:1678, Sources/App/Views/SettingsView.swift:706` · `qa: NOTE-04`
- **CMT-032** When the transcript text changes or becomes edited while the composer is open, the composer closes.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: COMMENT-02`
- **CMT-033** When a patient is deleted, the comments on all of their sessions are purged from the database.
  `surface: background` · `evidence: Sources/App/Services/Store.swift:390, Sources/App/Services/CommentStore.swift:229` · `qa: COMMENT-08`

## Export & archive (EXP)

- **EXP-001** When the user chooses Export All Records and picks a destination, a folder named "Aletheia records YYYY-MM-DD" (with " (2)" and so on added if that name is already taken, ignoring letter case) appears there, holding one "<Patient> records" folder per patient.
  `surface: ui` · `evidence: Sources/App/Services/AllRecordsExport.swift, Sources/App/Views/SettingsView.swift` · `qa: EXPORT-01`
- **EXP-002** When an all-records export is in progress, the folder is built under a hidden temporary name beside its final location and only takes its final name when every file is written, so the user never sees a half-finished "Aletheia records" folder.
  `surface: invariant` · `evidence: Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-01`
- **EXP-003** When the user cancels an all-records export, or it fails partway, the hidden temporary folder is removed and nothing is left behind in the chosen destination.
  `surface: ui` · `evidence: Sources/App/Services/AllRecordsExport.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-02`
- **EXP-004** When an all-records export finishes, the top of the export folder holds a "Read me.txt" with the date, "Patients: N", "Sessions: N" and "Recordings: N", a line for unreadable patient records and a line for unreadable session records (each only when there are any), and a statement that the files are not encrypted by Aletheia.
  `surface: invariant` · `evidence: Sources/App/Services/AllRecordsExport.swift, PRIVACY.md` · `qa: EXPORT-06`
- **EXP-005** When a patient has background information, their export folder contains "Patient notes.txt"; when the background is empty or only whitespace, that file is absent.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-06`
- **EXP-006** When a session is exported, its folder is named by the session's date and time in the Mac's time zone (YYYY-MM-DD HH.mm) and contains "Transcript.txt" unless the transcript is blank.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-07`
- **EXP-007** When a session has a summary but no saved notes, the exported session folder contains "Summary.txt"; when it has saved notes, it has no "Summary.txt".
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-07`
- **EXP-008** When two patients share a name, their export folders get distinct names rather than overwriting each other.
  `surface: invariant` · `evidence: Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-01`
- **EXP-009** When a patient name contains characters that are illegal in file names (/ \ : * ? " < > | or control characters), those characters become "-", leading dots are removed, and the name is cut to 80 characters; a name that ends up empty becomes "Untitled" in the archive, and a patient with an empty name gets the folder "Patient records".
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift, Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-08`
- **EXP-010** When two sessions for a patient start in the same minute, the later folder names end with " (2)", " (3)" and so on in date order, and sessions are listed oldest first.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-06`
- **EXP-011** When an all-records export includes a session that has no transcript, note or summary and no kept recording, it is left out and the patient's own "Read me.txt" says how many sessions were left out ("Sessions with no transcript or note (left out): N").
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-06`
- **EXP-012** When an all-records export runs, a toast titled "Exporting records" shows a progress bar, a stage label ("Starting", "Listing patients", "Patient N of M · session X of Y", then "Done") and a Cancel button.
  `surface: ui` · `evidence: Sources/App/Views/ExportStatusToast.swift, Sources/App/Services/AllRecordsExport.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-02`
- **EXP-013** When an export completes, the toast changes to "Export ready" with a summary ("N patients, N sessions, N files in a folder" for all records, "N sessions, N files in a zip of text files" for one patient), the output path as a link, "Done" and "Show in Finder" as the primary button.
  `surface: ui` · `evidence: Sources/App/Views/ExportStatusToast.swift` · `qa: EXPORT-03`
- **EXP-014** When an export fails, the toast reads "Export didn't finish" with a Dismiss button and the message "The export couldn't be finished: <reason>".
  `surface: ui` · `evidence: Sources/App/Views/ExportStatusToast.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-04`
- **EXP-015** When an export finishes or fails, a system notification appears titled "Export ready" ("Your records export is ready in Aletheia.") or "Export didn't finish" ("Open Aletheia to see why."), naming no patient; macOS does not show the banner while Aletheia is the frontmost app because the app sets no notification delegate.
  `surface: background` · `evidence: Sources/App/Services/ExportJobCenter.swift` · `qa: NOTIFY-05`
- **EXP-016** When an export is already running, the Export All Records button in Settings is disabled, so only one export runs at a time.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-02`
- **EXP-017** When the user picks an export folder that syncs to the cloud (iCloud Drive or a cloud-storage provider folder), a dialog titled "This folder syncs to the cloud" offers "Export Anyway", "Choose Another Folder…" and "Cancel" before anything is written.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-05`
- **EXP-018** When an all-records export finishes, the activity log gains a "Record exported" entry with the detail "All records, folder of N patients, N sessions".
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: EXPORT-03`
- **EXP-019** When the user clicks "Export all records" on a patient's page and picks a location (suggested name "<Patient> - Records.zip"), they get a single zip of text files with a "Read me.txt" and, under a "Sessions" folder, one folder for each session that has a transcript or note.
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift, Sources/App/Services/PatientArchive.swift, Sources/App/Services/ZipArchive.swift` · `qa: EXPORT-09`
- **EXP-020** When the user clicks Export on a note or summary, a popover offers PDF (selected each time it opens), Word and Markdown, with Cancel and Export buttons, and choosing Export opens a save panel.
  `surface: ui` · `evidence: Sources/App/Views/ExportButton.swift, Sources/App/Services/ExportFormat.swift` · `qa: EXPORT-10`
- **EXP-021** When a Markdown export is saved, the file starts with the title as a "# " heading, followed by the subtitle in italics, then the text, each part only if it is not empty; a whole-session export has the heading "# <patient>", a "**Date:**" line, then "## Summary" and "## Transcript" sections.
  `surface: invariant` · `evidence: Sources/App/Services/ExportFormat.swift, Sources/App/Views/SessionDetailView.swift` · `qa: EXPORT-10`
- **EXP-022** When a single-file export succeeds, an "Exported" alert shows the file path (home folder shown as ~) as a link that opens the file, with "Show in Finder" and "Done" as the default button; cancelling the save panel shows nothing.
  `surface: ui` · `evidence: Sources/App/Views/ExportResultAlert.swift, Sources/App/Services/FileSaver.swift` · `qa: EXPORT-10`
- **EXP-023** When the store is locked, an all-records export refuses to start and the failure reads "This data is encrypted. Unlock it with your recovery passphrase to open it." instead of writing unreadable files.
  `surface: ui` · `evidence: Sources/App/Services/AllRecordsExport.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-01`
- **EXP-024** When the user quits during an export, the export is cancelled ("Cancelling") and the app waits up to 2.5 seconds for it to stop, leaving no destination file or folder; if it hasn't stopped by then, quit proceeds and a hidden ".partial-" staging folder may remain.
  `surface: background` · `evidence: Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-02`
- **EXP-025** Settings → Backups offers an "Export All Records…" button with a caption saying it copies every patient's notes, transcripts, comments and kept recordings into ordinary files that open without Aletheia and never need a license key.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, PRIVACY.md, SECURITY.md, README.md` · `qa: BACKUP-03`
- **EXP-026** When a session has saved notes, its exported folder contains one "Note - <format name>.txt" per note, as plain text with Markdown formatting removed.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-07`
- **EXP-027** When a session has comments or a psychotherapy note, its all-records folder still holds neither: they stay out of the clinical record and are exported only on their own.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-07`
- **EXP-028** When psychotherapy notes are exported on their own, each session folder holds "Psychotherapy note.txt" and "Private comments.txt"; in "Private comments.txt" each comment is a block starting with its timestamp in [M:SS] (H:MM:SS past an hour) and the quoted passage in curly quotes, then the comment text, then "(Resolved)" if it was resolved.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-07`
- **EXP-029** When an all-records export includes a session with kept audio, the session folder holds "Recording - microphone.caf" and "Recording - call.caf" only for the recordings that exist, and a session with only a recording is still exported.
  `surface: invariant` · `evidence: Sources/App/Services/AllRecordsExport.swift, Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-07`
- **EXP-030** When a patient's session has only a recording and no text, the one-patient zip counts it as left out (the zip holds no recordings), whereas the all-records folder includes it.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift, Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-09`
- **EXP-031** When the user picks an export folder on a disk that is not encrypted, a dialog titled "This disk isn't encrypted" offers "Export Anyway", "Choose Another Folder…" and "Cancel" before anything is written.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-12`
- **EXP-032** When Aletheia cannot tell whether the chosen disk is encrypted, the dialog is titled "Couldn't confirm this disk is encrypted" with the same three buttons, and when several warnings apply the title is the first warning's and the message joins them all.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-05`
- **EXP-033** When a patient's records exceed 65,535 files or 4 GB, the zip export fails with "These records are too large to save as one zip file."
  `surface: ui` · `evidence: Sources/App/Services/ZipArchive.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-09`
- **EXP-034** When the one-patient zip is made, it contains text files only and no audio recordings.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-09`
- **EXP-035** When the one-patient zip is saved, it is not encrypted by Aletheia, and the archive's "Read me.txt" carries the same warning.
  `surface: invariant` · `evidence: Sources/App/Services/ZipArchive.swift, Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-09`
- **EXP-036** When the one-patient zip is written, it is saved atomically, so cancelling leaves no zip file at the chosen location.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-09`
- **EXP-037** When a session's transcript exists but cannot be read, the export fails rather than silently leaving that transcript out.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-09`
- **EXP-038** When a single-file export cannot be saved, an "Export failed" alert shows "<file> couldn't be saved." with the reason and an OK button, and when the file cannot be built it reads "The <format> file couldn't be made."
  `surface: ui` · `evidence: Sources/App/Views/ExportResultAlert.swift, Sources/App/Services/FileSaver.swift, Sources/App/Services/ExportFormat.swift` · `qa: EXPORT-11`
- **EXP-039** When a whole-session, note or patient-zip export is saved, the activity log gains a "Record exported" entry ("Session, <format>", "Note <name>, <format>" or "Patient records, zip of N sessions"); nothing is logged if the user cancels.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift, Sources/App/Views/PatientDetailView.swift` · `qa: EXPORT-09`
- **EXP-040** The Backups caption and each export's "Read me.txt" tell the user the copy is not encrypted by Aletheia and should go on an encrypted disk, and to delete it when their record-keeping rules allow.
  `surface: invariant` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AllRecordsExport.swift, PRIVACY.md` · `qa: EXPORT-06`
- **EXP-041** When an all-records export starts, Aletheia asks macOS for permission to show notifications.
  `surface: background` · `evidence: Sources/App/Services/ExportJobCenter.swift` · `qa: NOTIFY-01`
- **EXP-042** When the user cancels an export, the toast goes away with no message and no notification is posted.
  `surface: ui` · `evidence: Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-02`
- **EXP-043** When an all-records export is running, Settings shows the current stage label beside the Export All Records button.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: EXPORT-02`
- **EXP-044** When the Export all records button on a patient's page is used with no sessions, or while an export is running, it is disabled, and while running its tooltip reads "An export is already running".
  `surface: ui` · `evidence: Sources/App/Views/PatientDetailView.swift` · `qa: EXPORT-09`
- **EXP-045** When a transcript is exported to a file, it is rewritten for the reader: call audio is labelled with the client's first name and " (overlapping)" markers are removed.
  `surface: invariant` · `evidence: Sources/App/Services/PatientArchive.swift` · `qa: EXPORT-07`
- **EXP-046** When recordings are exported while encryption is on, the files in the export are decrypted copies that open in ordinary audio players.
  `surface: invariant` · `evidence: Sources/App/Services/AllRecordsExport.swift` · `qa: EXPORT-07`
- **EXP-047** When the user exports a session or note, the Export button only appears if the session has a transcript or summary.
  `surface: ui` · `evidence: Sources/App/Views/SessionDetailView.swift` · `qa: EXPORT-10`
- **EXP-048** When an all-records export starts while another is running, the second request is ignored and the first continues.
  `surface: invariant` · `evidence: Sources/App/Services/ExportJobCenter.swift` · `qa: EXPORT-02`

## Network, privacy invariants & helper (NET)

- **NET-001** The main app's signed entitlements never include outbound network access, in the production build or the developer build.
  `surface: invariant` · `evidence: Sources/App/Resources/Aletheia.entitlements, Sources/App/Resources/AletheiaDev.entitlements, scripts/check-entitlements.sh` · `qa: BUILD-01`
- **NET-002** The network helper's signed entitlements consist of exactly the sandbox and outbound network, with no file, keychain or shared-group access.
  `surface: invariant` · `evidence: Sources/NetworkHelper/NetworkHelper.entitlements, scripts/check-entitlements.sh` · `qa: BUILD-02`
- **NET-003** When Aletheia makes an internet request of its own, the connection is made by the bundled helper process and the main app opens no sockets or URL sessions itself; links the user opens (feedback, GitHub) are opened in the user's browser.
  `surface: invariant` · `evidence: Sources/App/Services/NetworkHelper/NetworkHelperClient.swift, Tests/AletheiaTests/NetworkHelperSourceTests.swift` · `qa: BUILD-07`
- **NET-004** The app's only outbound traffic is the update check, the update download, and opt-in model downloads, made through the helper; none carries patient data.
  `surface: invariant` · `evidence: PRIVACY.md, Sources/NetworkHelperShared/NetworkHelperProtocol.swift, Sources/App/Services/NetworkHelper/NetworkAccessStatus.swift` · `qa: BUILD-07`
- **NET-005** The helper only fetches https addresses on port 443 (or no explicit port) at github.com, githubusercontent.com, huggingface.co and hf.co or their subdomains, with no username or password in the address.
  `surface: invariant` · `evidence: Sources/NetworkHelper/AssetCatalog.swift, Sources/NetworkHelper/HelperFetcher.swift` · `qa: BUILD-08`
- **NET-006** When a download redirects to a host outside the allowed list, or ends at one, the request is refused.
  `surface: invariant` · `evidence: Sources/NetworkHelper/HelperFetcher.swift` · `qa: BUILD-08`
- **NET-007** Requests are plain GETs on an ephemeral session that sends no cookies, stored credentials or cache, requires TLS 1.2 or newer, and treats any answer other than HTTP 200 as a failure.
  `surface: invariant` · `evidence: Sources/NetworkHelper/HelperFetcher.swift` · `qa: BUILD-08`
- **NET-008** When the app asks the helper for something, it names it only by a fixed integer asset number (or one of two argument-free commands); the app cannot hand the helper a web address, text or data to send, and an unknown asset number is refused.
  `surface: invariant` · `evidence: Sources/App/Services/NetworkHelper/AssetID.swift, Sources/NetworkHelperShared/NetworkHelperProtocol.swift, Sources/NetworkHelper/HelperService.swift` · `qa: BUILD-08`
- **NET-009** When the helper reads the update feed or the revocation list and the response is larger than 256 KB, it is rejected; the update feed must also be a JSON object.
  `surface: invariant` · `evidence: Sources/NetworkHelper/HelperFetcher.swift` · `qa: BUILD-08`
- **NET-010** When a model download is requested, the file is fetched from a pinned revision on huggingface.co, and the app (not the helper) checks its SHA-256 before the model becomes usable.
  `surface: background` · `evidence: Sources/NetworkHelper/AssetCatalog.swift, Sources/App/Services/NetworkHelper/ModelFileInstaller.swift, Sources/App/Services/ModelDigest.swift` · `qa: BUILD-08`
- **NET-011** When a downloaded model's checksum does not match, the partial file is deleted, any existing good model file is left untouched, and the user sees "The downloaded model failed its integrity check and was discarded. Please try downloading it again."
  `surface: background` · `evidence: Sources/App/Services/NetworkHelper/ModelFileInstaller.swift, Sources/App/Services/WhisperModelDownloader.swift` · `qa: BUILD-09`
- **NET-012** When a model is downloading, the app creates a "<name>.download" file readable only by its owner and hands the helper a write-only handle to it; the file is moved to "<name>.partial", verified, and only then swapped into place.
  `surface: background` · `evidence: Sources/App/Services/NetworkHelper/NetworkHelperClient.swift, Sources/App/Services/NetworkHelper/ModelFileInstaller.swift` · `qa: BUILD-08`
- **NET-013** When the user cancels a download, or the app quits or crashes mid-download, the helper cancels the running transfer.
  `surface: background` · `evidence: Sources/NetworkHelper/HelperTasks.swift, Sources/NetworkHelper/HelperService.swift` · `qa: BUILD-08`
- **NET-014** When the shipped build's Settings → Security opens, the Network access card reads "Aletheia can't connect to the internet" with a "No network" chip.
  `surface: ui` · `evidence: Sources/App/Views/Settings/NetworkAccessView.swift, Sources/App/Services/NetworkHelper/NetworkAccessStatus.swift` · `qa: SECURITY-02`
- **NET-015** When the Network access card is shown, it lists the helper's hosts and downloads and says the helper is "Sandboxed, with network access and nothing else: no files, no microphone, no patient data."
  `surface: ui` · `evidence: Sources/App/Views/Settings/NetworkAccessView.swift, Sources/App/Services/NetworkHelper/NetworkAccessStatus.swift` · `qa: SECURITY-02`
- **NET-016** When the user copies patient content, it is marked concealed and transient and is restricted to this Mac so clipboard managers and Universal Clipboard do not keep it.
  `surface: invariant` · `evidence: Sources/App/Services/PHIPasteboard.swift, Sources/App/Services/RichClipboard.swift` · `qa: LOCK-07`
- **NET-017** When the user presses Report a Bug or Request a Feature (sidebar button, Help menu or Doctor window), their browser opens astrealabs.com/feedback with only the project, type and an environment line (app version, build tier, macOS version, chip), and no patient data.
  `surface: ui` · `evidence: Sources/App/Services/FeedbackLink.swift, Sources/App/AletheiaApp.swift, Sources/App/Views/PatientsListView.swift, PRIVACY.md` · `qa: MENUBAR-12`
- **NET-018** When the user hovers the bug button in the sidebar, the tip reads "Report a bug (beta): opens the feedback form on astrealabs.com".
  `surface: ui` · `evidence: Sources/App/Services/FeedbackLink.swift` · `qa: MENUBAR-12`
- **NET-019** The app contains no analytics, telemetry, crash-reporting or advertising component, and the secret-scan workflow fails if one is added.
  `surface: invariant` · `evidence: scripts/check-no-telemetry-sdk.sh, .github/workflows/secret-scan.yml, PRIVACY.md` · `qa: BUILD-05`
- **NET-020** The app monitors only whether the Mac is online and never sends probe requests to test connectivity.
  `surface: invariant` · `evidence: Sources/App/Services/NetworkReachability.swift` · `qa: BUILD-07`
- **NET-021** Apple Intelligence is turned off on purpose, the AI settings say so, and AI features run only in the engine built into the app on this Mac.
  `surface: invariant` · `evidence: README.md, Sources/App/Views/SettingsView.swift, Tests/AletheiaTests/AppleIntelligenceBlockTests.swift` · `qa: SETTINGS-06`
- **NET-022** When the helper is asked for the license-revocation list, it refuses with "The license revocation list isn't configured yet." and makes no request; nothing in the app currently asks for it.
  `surface: background` · `evidence: Sources/NetworkHelper/HelperFetcher.swift, Sources/NetworkHelper/AssetCatalog.swift, Sources/App/Services/Updates/RevocationFetchPolicy.swift` · `qa: BUILD-08`
- **NET-023** When a build has network access but is otherwise sandboxed, the Network access card reads "Aletheia can connect to the internet" with a "Review" chip.
  `surface: ui` · `evidence: Sources/App/Services/NetworkHelper/NetworkAccessStatus.swift` · `qa: SECURITY-02`
- **NET-024** When the app is not sandboxed (a development build) the card reads "Not sandboxed (development build)", and when entitlements cannot be read it reads "Couldn't check network access".
  `surface: ui` · `evidence: Sources/App/Services/NetworkHelper/NetworkAccessStatus.swift` · `qa: SECURITY-02`
- **NET-025** When the user presses the Copy button under "Verify it yourself", the codesign command for the running app is copied (concealed, transient, this Mac only), the button reads "Copied" for 2 seconds, and the text names LuLu, Little Snitch and nettop as other ways to check.
  `surface: ui` · `evidence: Sources/App/Views/Settings/NetworkAccessView.swift, Sources/App/Services/PHIPasteboard.swift` · `qa: SECURITY-03`
- **NET-026** The update feed is fetched from github.com/mgwedd/aletheia releases (latest download "appcast.json"), and the update archive is only accepted from a github.com download address under /mgwedd/aletheia/releases/download/.
  `surface: invariant` · `evidence: Sources/NetworkHelper/AssetCatalog.swift` · `qa: BUILD-08`
- **NET-027** The main app is sandboxed with only the microphone and user-selected-file entitlements in production (the developer build adds calendar access), and no network entitlement.
  `surface: invariant` · `evidence: Sources/App/Resources/Aletheia.entitlements, Sources/App/Resources/AletheiaDev.entitlements` · `qa: BUILD-01`
- **NET-028** When the user dictates, speech is recognised on the Mac only, and the voice-input option is offered only when on-device recognition is supported.
  `surface: invariant` · `evidence: Sources/App/Services/VoiceInput.swift` · `qa: BUILD-07`
- **NET-029** When the security posture view shows network status, it reads "This Mac is online, but no patient data is sent. Transcription and AI run locally." or "This Mac is offline. Aletheia is fully functional without a network."
  `surface: ui` · `evidence: Sources/App/Services/SecurityPosture.swift, Sources/App/Services/NetworkReachability.swift` · `qa: SECURITY-01`
- **NET-030** When a release is built, the built app is checked for entitlements by the release workflow, and the source entitlement checks run in the smoke-test workflow.
  `surface: invariant` · `evidence: scripts/check-entitlements.sh, .github/workflows/release.yml, .github/workflows/smoke-test.yml` · `qa: BUILD-08`

## Updates (UPD)

- **UPD-001** When Aletheia launches with "Check for updates automatically" on, it checks for a newer version, and again each time the user switches back to the app, subject to the 30-minute limit.
  `surface: background` · `evidence: Sources/App/AletheiaApp.swift, docs/SETUP-GUIDE.md` · `qa: UPDATE-09`
- **UPD-002** When checks happen repeatedly, at most one automatic check is made every 30 minutes; any check, including a failed or manual one, restarts the 30 minutes, and a check already running is ignored.
  `surface: background` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-09`
- **UPD-003** When "Check for updates automatically" is off, no check happens until the user asks.
  `surface: background` · `evidence: Sources/App/AletheiaApp.swift, Sources/App/Services/AppSettings.swift` · `qa: UPDATE-09`
- **UPD-004** On a fresh install, "Check for updates automatically" is on.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift` · `qa: UPDATE-01`
- **UPD-005** When the user chooses Check for Updates… from the app menu or Settings, a check runs immediately regardless of the 30-minute limit.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift, Sources/App/Views/SettingsView.swift` · `qa: UPDATE-02`
- **UPD-006** When a manual check finds no newer version, no alert or banner appears; only the Settings row says you are up to date.
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-02`
- **UPD-007** When a check cannot reach the update feed, no alert appears; after a manual check the Settings row says "Couldn't check for updates".
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-03`
- **UPD-008** When a newer version exists, a non-blocking banner above the main window reads "Aletheia X is available." with "What's New…", "Remind me later" and "Download update"; "What's New…" opens a prompt titled "Aletheia X is available" says "You have Y.", and shows a "What is new" section from the release notes only if the notes contain text beyond headings and list markers.
  `surface: ui` · `evidence: Sources/App/Views/UpdatePromptView.swift` · `qa: UPDATE-04`
- **UPD-009** When the update prompt appears, it offers "View downloads", "Skip this version", "Remind me later" and "Download update", with Download update as the default.
  `surface: ui` · `evidence: Sources/App/Views/UpdatePromptView.swift` · `qa: UPDATE-04`
- **UPD-010** When the user chooses "Skip this version", that version is remembered and not offered again by automatic checks.
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-06`
- **UPD-011** When the prompt is shown, a caption states that the version check sent no client data.
  `surface: ui` · `evidence: Sources/App/Views/UpdatePromptView.swift` · `qa: UPDATE-04`
- **UPD-012** When the release lists a checksum and the user chooses Download update, the disk image downloads to the app's Caches/Updates folder as "Aletheia-update.dmg", is verified, and then opens.
  `surface: background` · `evidence: Sources/App/Services/Updates/UpdateInstalling.swift, Sources/App/Services/NetworkHelper/AssetID.swift` · `qa: UPDATE-07`
- **UPD-013** When the release lists no checksum, Download update opens the downloads page in the browser instead of downloading.
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateInstalling.swift` · `qa: UPDATE-08`
- **UPD-014** When a downloaded update's checksum does not match, the file is deleted and never opened, and the generic releases page (not this version's page) opens in the browser instead.
  `surface: background` · `evidence: Sources/App/Services/Updates/UpdateInstalling.swift, Sources/App/Services/NetworkHelper/ModelFileInstaller.swift` · `qa: UPDATE-08`
- **UPD-015** The update archive is only accepted from a github.com/mgwedd/aletheia releases download address with no "." or ".." segments.
  `surface: invariant` · `evidence: Sources/NetworkHelper/AssetCatalog.swift` · `qa: UPDATE-07`
- **UPD-016** Updates never install themselves and never quit the app; the user quits Aletheia when ready and drags the new version into Applications.
  `surface: ui` · `evidence: Sources/App/Views/UpdatePromptView.swift, Sources/App/Services/Updates/UpdateService.swift, docs/SETUP-GUIDE.md` · `qa: UPDATE-07`
- **UPD-017** When the user opens Settings → General, the software update section shows the current version, the automatic-check switch with the detail "Aletheia checks on launch and when switching back to the app.", a "Check for updates" row and a "View Releases on GitHub" link.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: UPDATE-01`
- **UPD-018** When a check is running in Settings, a spinner and "Checking…" replace the button, then the row shows "You're up to date (checked at …)", "Couldn't check for updates", or "vX available".
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: UPDATE-02`
- **UPD-019** Versions are compared by their numeric parts (1, 1.2 or 1.2.3), ignoring pre-release and build suffixes.
  `surface: invariant` · `evidence: Sources/App/Services/Updates/SemanticVersion.swift` · `qa: UPDATE-04`
- **UPD-020** When the user skipped a version, a manual check treats that version as up to date rather than offering it, while a newer version is still offered.
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-06`
- **UPD-021** When the user chooses Download update, the prompt closes and Aletheia stays open so unsaved work can be finished.
  `surface: ui` · `evidence: Sources/App/Views/UpdatePromptView.swift, Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-07`
- **UPD-022** When the verified download fails for any reason (network error, bad checksum), Download update opens the downloads page in the browser instead.
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateInstalling.swift` · `qa: UPDATE-08`
- **UPD-024** When the user chooses "Remind me later", the prompt closes and the same version is offered again at a later check.
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-05`
- **UPD-025** When the user has already downloaded an update during this run, the same version is not offered again until Aletheia is relaunched.
  `surface: background` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-07`
- **UPD-026** When the user chooses "View downloads" in the update prompt, the downloads page on astrealabs.com opens in the browser; links from the update feed are never opened.
  `surface: ui` · `evidence: Sources/App/Views/UpdatePromptView.swift, Sources/App/Services/Updates/UpdateInstalling.swift` · `qa: UPDATE-04`
- **UPD-027** When a version string is not numeric, it is treated as not newer, so no prompt appears for it.
  `surface: invariant` · `evidence: Sources/App/Services/Updates/SemanticVersion.swift` · `qa: UPDATE-04`
- **UPD-028** When an automatic check fails, any previously shown available update is cleared and nothing is shown.
  `surface: background` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-03`
- **UPD-029** When the user asks to download an update whose release lists no checksum, nothing is downloaded and the downloads page opens instead.
  `surface: ui` · `evidence: Sources/App/Services/Updates/UpdateService.swift` · `qa: UPDATE-10`

## OS integrations (OSI)

- **OSI-001** When the app is unlocked and the user presses "Start recording" in the menu-bar item with a patient selected, a new session starts for that patient and the main window opens on that patient.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift, Sources/App/Services/MenuBarContentPolicy.swift` · `qa: MENUBAR-03`
- **OSI-002** When a recording is running, the menu-bar icon changes to a record symbol, to a pause symbol when paused, and is a waveform when idle.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift` · `qa: MENUBAR-01`
- **OSI-003** When a system notification is shown with the default setting, its text is generic and carries no patient name or session date.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/AppSettings.swift:461` · `qa: NOTIFY-02`
- **OSI-004** When the user turns on "Show patient names in notifications", session notifications name the patient in full (not by initials) and give the session date; export notifications stay generic.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Views/SettingsView.swift` · `qa: NOTIFY-06`
- **OSI-005** When a recording is still running 90 minutes of clock time after it started, a "Still recording" system notification reading "A session has been recording for over 90 minutes. Did you forget to end it?" is posted once, and only if the user has allowed notifications.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/Notifications/UserNotificationService.swift` · `qa: RECORD-08`
- **OSI-006** When a transcript has been saved, a "Transcript ready" notification reads "A session has finished transcribing. Open Aletheia to see it."
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift` · `qa: NOTIFY-02`
- **OSI-007** When a transcription or an export starts, macOS asks for notification permission if it has not been decided, and a notification is posted only if the user allowed it.
  `surface: background` · `evidence: Sources/App/Services/Notifications/UserNotificationService.swift, Sources/App/Services/TranscriptionCoordinator.swift` · `qa: NOTIFY-01`
- **OSI-008** When the user presses Cmd+/ or opens Help → Keyboard Shortcuts, a Keyboard Shortcuts window opens.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift, Sources/App/Views/ShortcutsView.swift` · `qa: MENUBAR-10`
- **OSI-009** When the user chooses Help → Report a Bug… or Request a Feature…, the feedback form on astrealabs.com opens in the browser.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift:262` · `qa: MENUBAR-12`
- **OSI-010** When the user opens the app menu, a "Check for Updates…" item sits after About and checks for a new version at once.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift:242` · `qa: UPDATE-02`
- **OSI-011** In the production build, patient sessions are never added to Spotlight, any earlier index is cleared, and Settings shows no Spotlight option.
  `surface: invariant` · `evidence: Sources/App/Services/AppModel.swift:489, Sources/App/Services/Spotlight/SpotlightFeatureModule.swift, Sources/App/Views/SettingsView.swift:208` · `qa: SEARCH-12`
- **OSI-012** When a preview or developer build is first used, Spotlight indexing is off until the user turns on "Find patients in Spotlight".
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift:443, Sources/App/Views/SettingsView.swift:210` · `qa: SEARCH-12`
- **OSI-013** When Spotlight indexing is on, each result's description reads "Therapy patient in Aletheia." for a patient or "Therapy session on <long date>." for a session.
  `surface: background` · `evidence: Sources/App/Services/Spotlight/SpotlightItemBuilder.swift` · `qa: SEARCH-12`
- **OSI-014** When Spotlight indexing is turned off in Settings, all previously indexed results are removed.
  `surface: background` · `evidence: Sources/App/Services/AppModel.swift:489, Sources/App/Services/Spotlight/SpotlightIndexer.swift` · `qa: SEARCH-12`
- **OSI-015** When the user opens a Spotlight result while Aletheia is locked, nothing opens.
  `surface: ui` · `evidence: Sources/App/Services/Spotlight/SpotlightContinuationModifier.swift` · `qa: SEARCH-12`
- **OSI-016** When Aletheia becomes locked, Spotlight results are removed.
  `surface: background` · `evidence: Sources/App/Services/AppModel.swift:494, Sources/App/Views/SettingsView.swift:211` · `qa: SEARCH-12`
- **OSI-017** In the production (Release) build, the app requests no Calendar or Reminders access, and its signed entitlements and purpose strings contain none.
  `surface: invariant` · `evidence: Sources/App/Resources/Aletheia.entitlements, Sources/App/Resources/Info.plist, scripts/check-entitlements.sh` · `qa: BUILD-01`
- **OSI-018** In a developer build, the Schedule Next Session sheet offers the quick-picks "Next week", "In 2 weeks" and "In 4 weeks", which set the start 7, 14 or 28 days out at the same time of day.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-019** When a next session is scheduled, a Calendar event titled "Therapy session" with the note "Therapy session." is added, naming no patient.
  `surface: ui` · `evidence: Sources/App/Services/Calendar/SessionEventBuilder.swift, Sources/App/Services/Calendar/CalendarScheduler.swift` · `qa: SESSION-06`
- **OSI-020** When "Save an .ics file" is ticked and the user schedules, a save panel lets them store an iCalendar file with the same title, times and repeat rule, and no patient name inside it.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift, Sources/App/Services/Calendar/SessionEventBuilder.swift` · `qa: SESSION-06`
- **OSI-021** When Calendar access is refused, the sheet says "Aletheia doesn't have permission to add Calendar events. Turn it on in System Settings › Privacy & Security › Calendars."
  `surface: ui` · `evidence: Sources/App/Services/Calendar/CalendarScheduler.swift` · `qa: SESSION-06`
- **OSI-022** When the user picks Tomorrow, In 3 days or Next week from the session's Remind Me menu, a reminder titled "Follow up (Aletheia)" with the note "Re: therapy session on <long date>." is created for 9:00 AM that day with an alarm, naming no patient.
  `surface: ui` · `evidence: Sources/App/Services/Reminders/SessionReminderBuilder.swift, Sources/App/Services/Reminders/ReminderScheduler.swift` · `qa: SESSION-07`
- **OSI-023** In a developer build, the Shortcuts app offers the actions "Show Today's Sessions", "Open Patient" and "New Session".
  `surface: ui` · `evidence: Sources/App/Intents/AletheiaIntents.swift` · `qa: SESSION-08`
- **OSI-024** In developer builds, when Aletheia is locked, Siri and Shortcuts actions reply "Aletheia is locked. Unlock it first." and expose no patients; the production build ships no Siri or Shortcuts actions.
  `surface: ui` · `evidence: Sources/App/Intents/AletheiaIntents.swift, Sources/App/Intents/PatientEntity.swift` · `qa: SESSION-08`
- **OSI-025** In the production and preview builds, Siri and Shortcuts expose no Aletheia actions.
  `surface: invariant` · `evidence: Sources/App/Intents/AppIntentsFeatureModule.swift, Sources/App/Services/Features/FeatureRegistry.swift` · `qa: SESSION-05`
- **OSI-026** When Full Keyboard Access is on and a button has keyboard focus, Return or keypad Enter presses it, except inside text fields.
  `surface: ui` · `evidence: Sources/App/Services/ReturnKeyActivation.swift` · `qa: MENUBAR-11`
- **OSI-027** When Aletheia is locked, the menu-bar item shows "Aletheia is locked" with an "Unlock" button and no Start or recording controls.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift, Sources/App/Services/MenuBarContentPolicy.swift` · `qa: MENUBAR-09`
- **OSI-028** When no patients exist, the idle menu-bar item says "Add a patient in the main window first."
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift` · `qa: MENUBAR-07`
- **OSI-029** When no patient is selected or a recording is starting, the menu-bar "Start recording" button is disabled.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift, Sources/App/Services/MenuBarContentPolicy.swift` · `qa: MENUBAR-15`
- **OSI-030** When starting from the menu bar fails, the reason appears as a line under the button, for example "Couldn't create a session. Check the data folder in Settings."
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift` · `qa: MENUBAR-08`
- **OSI-031** When a recording is running or paused, the menu-bar item shows a "Recording" or "Paused" chip, the patient's initials (the full name only when "Show patient names in notifications and the menu bar" is on), an HH:MM:SS timer, Mic and Call level bars, Pause or Resume, and "Stop and save".
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift` · `qa: MENUBAR-04`
- **OSI-032** When a recording is paused, the menu-bar item says "Nothing is being captured. Resume to continue the same session."
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift` · `qa: MENUBAR-05`
- **OSI-033** When the app is unlocked, the menu-bar item also offers "Open Aletheia", "Quit Aletheia", and "Show this session" while a session is active.
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift` · `qa: MENUBAR-02`
- **OSI-034** When a transcription fails or finds no speech, a "Transcription needs attention" notification reads "A session wasn't transcribed. Open Aletheia to see why."
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/TranscriptionCoordinator.swift` · `qa: NOTIFY-03`
- **OSI-035** When a session is transcribed but its recording could not be deleted, a "Recording still on disk" notification reads "A session was transcribed, but its recording couldn't be deleted. Open Aletheia to see why."
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/TranscriptionCoordinator.swift` · `qa: NOTIFY-03`
- **OSI-036** When an AI note has been generated and saved, a "Summary ready" notification reads "An AI summary is ready to review in Aletheia."
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Views/SessionDetailView.swift` · `qa: NOTIFY-04`
- **OSI-037** When an export finishes, an "Export ready" notification reads "Your records export is ready in Aletheia." whatever the patient-names setting is.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: NOTIFY-05`
- **OSI-038** When an export does not finish, an "Export didn't finish" notification reads "Open Aletheia to see why." whatever the patient-names setting is.
  `surface: background` · `evidence: Sources/App/Services/Notifications/SessionNotifications.swift, Sources/App/Services/ExportJobCenter.swift` · `qa: NOTIFY-05`
- **OSI-039** When the user cancels a transcription, no notification is posted.
  `surface: background` · `evidence: Sources/App/Services/TranscriptionCoordinator.swift` · `qa: TRANSCRIBE-05`
- **OSI-040** When a recording reaches 90 minutes, an in-app "Still recording" alert also appears with "Keep Recording" and "Stop Now" and names the patient.
  `surface: ui` · `evidence: Sources/App/Views/RootView.swift` · `qa: RECORD-08`
- **OSI-041** When the Doctor module is in the build, the Help menu offers "Aletheia Doctor…", which opens the Doctor window.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift:254` · `qa: SECURITY-07`
- **OSI-042** When the user presses Cmd+, Settings opens.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift, Sources/App/Services/ShortcutCatalog.swift` · `qa: SETTINGS-01`
- **OSI-043** When Spotlight indexing is on, each result is titled with the patient's initials (for a session, "<initials> — <long date>"), never the full name.
  `surface: background` · `evidence: Sources/App/Services/Spotlight/SpotlightItemBuilder.swift, Sources/App/Services/PatientLabel.swift` · `qa: SEARCH-12`
- **OSI-044** When the user unlocks Aletheia with Spotlight indexing on, the Spotlight results are rebuilt.
  `surface: background` · `evidence: Sources/App/AletheiaApp.swift:133, Sources/App/Services/AppModel.swift:489` · `qa: SEARCH-12`
- **OSI-045** In the Schedule Next Session sheet, the Length menu offers 30, 45, 50, 60 and 90 minutes.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-046** In the Schedule Next Session sheet, the Repeat menu offers Never, Every week, Every 2 weeks, Every 4 weeks and Every month.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift, Sources/App/Services/Calendar/SessionEventBuilder.swift` · `qa: SESSION-06`
- **OSI-047** When the Schedule Next Session sheet opens, it proposes a start one week out at 9:00.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-048** When the Schedule Next Session sheet opens, the length is 50 minutes, Repeat is Never and "Save an .ics file" is unticked.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-049** When a next session is scheduled, the event ends at the start plus the chosen length.
  `surface: ui` · `evidence: Sources/App/Services/Calendar/SessionEventBuilder.swift` · `qa: SESSION-06`
- **OSI-050** When a repeat other than Never is chosen, the Calendar event repeats with no end date.
  `surface: ui` · `evidence: Sources/App/Services/Calendar/SessionEventBuilder.swift` · `qa: SESSION-06`
- **OSI-051** When the save panel for the .ics file opens, its suggested file name contains the patient's name.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-052** When the user schedules with "Save an .ics file" ticked, the file is saved first and then the Calendar event is added.
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-053** When the .ics file was saved but adding to Calendar fails, the sheet says "Saved .ics file. Could not add to Calendar: <error>".
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-054** When no calendar can take the event, the sheet says "No calendar is available to add the event to."
  `surface: ui` · `evidence: Sources/App/Services/Calendar/CalendarScheduler.swift` · `qa: SESSION-06`
- **OSI-055** When a next session is scheduled, the sheet confirms with "Added “Therapy session” to your Calendar." or, with the file, "Added “Therapy session” to your Calendar and saved .ics file."
  `surface: ui` · `evidence: Sources/App/Views/ScheduleNextSessionSheet.swift` · `qa: SESSION-06`
- **OSI-056** When a reminder is created, the app confirms "Reminder set for <lead time> at 9:00 AM."
  `surface: ui` · `evidence: Sources/App/Services/Reminders/ReminderScheduler.swift` · `qa: SESSION-07`
- **OSI-057** When Reminders access is refused, the app says "Aletheia doesn't have permission to add Reminders. Turn it on in System Settings › Privacy & Security › Reminders."
  `surface: ui` · `evidence: Sources/App/Services/Reminders/ReminderScheduler.swift` · `qa: SESSION-07`
- **OSI-058** In a developer build, Siri responds to "Show today's sessions" and "What sessions do I have today", and no other Aletheia action has a spoken phrase.
  `surface: ui` · `evidence: Sources/App/Intents/AletheiaIntents.swift` · `qa: SESSION-08`
- **OSI-059** When a Siri or Shortcuts action lists patients, each appears as initials only.
  `surface: ui` · `evidence: Sources/App/Intents/PatientEntity.swift, Sources/App/Services/PatientLabel.swift` · `qa: SESSION-08`
- **OSI-060** When "Show Today's Sessions" runs, it says "You have no sessions recorded today." or "You have N session(s) today: <initials>, …".
  `surface: ui` · `evidence: Sources/App/Intents/AletheiaIntents.swift` · `qa: SESSION-08`
- **OSI-061** When "New Session" cannot start, it says "Open Aletheia and choose a data folder first." or "I couldn't find that patient.", and on success "Started a new session."
  `surface: ui` · `evidence: Sources/App/Intents/AletheiaIntents.swift` · `qa: SESSION-08`
- **OSI-062** When the idle menu-bar item is open, it reads "Records a new session. Make sure your client has consented first."
  `surface: ui` · `evidence: Sources/App/Views/RecordingMenuBar.swift` · `qa: MENUBAR-02`

## Onboarding & setup (STP)

- **STP-001** When Aletheia launches with no data folder chosen, setup unfinished or the current terms not accepted, a "Set up Aletheia" sheet appears that the user cannot dismiss.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift, Sources/App/Views/FirstRunView.swift` · `qa: SETUP-01`
- **STP-002** When the setup sheet is shown, it says "Recording, transcription and the AI all run on this Mac. Client data is never sent to a server. Downloads happen once."
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift` · `qa: SETUP-01`
- **STP-003** When the setup checklist is shown, it lists Terms & Privacy, Data folder, Microphone access, Call audio capture, Transcription model and AI summaries & chat in that order, with an "N of M done" counter.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift, Sources/App/Views/SetupChecklistView.swift` · `qa: SETUP-02`
- **STP-004** When no data folder has been chosen, Finish setup is disabled and the footer says "Choose a data folder above to continue."
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift` · `qa: SETUP-04`
- **STP-005** When the folder is chosen and the terms are accepted, Finish setup is enabled and the footer says "You can finish the rest of the checklist now or any time from Settings." even if other items are incomplete.
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift` · `qa: SETUP-06`
- **STP-006** When the microphone has not been decided, its checklist row says "You'll be asked to allow this the first time you record."
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift` · `qa: SETUP-07`
- **STP-007** When call-audio capture is not yet allowed, its row says "Click Allow to grant Screen & System Audio Recording. This updates here as soon as you approve — no restart needed." and turns to done once macOS permission is granted.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift, Sources/App/Services/SystemSettingsLinks.swift` · `qa: SETUP-08`
- **STP-008** When the speech model has not been downloaded, its row says "Not downloaded yet. Open Settings to download it (about N MB)." and offers a Download action with a license link and progress.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift, Sources/App/Views/SetupChecklistView.swift` · `qa: SETUP-09`
- **STP-009** When the setup sheet is shown, it warns "Recording a session requires the client's consent and compliance with your licensing board's rules — that's on you to confirm before you hit record." with a link "Read the consent guide before recording anyone…".
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift, Sources/App/Views/ConsentGuideView.swift` · `qa: SETUP-05`
- **STP-010** When the user opens the consent guide, it shows "1. Informed Consent Standards", "2. Jurisdiction & Wiretapping Laws", "3. On-Device Privacy Guarantees" and "4. Client Rights & Revocation", then a "SAMPLE INFORMED CONSENT CLAUSE".
  `surface: ui` · `evidence: Sources/App/Views/ConsentGuideView.swift:16` · `qa: SETUP-05`
- **STP-011** When the build has no at-rest encryption (production), the setup sheet shows no "Protect your data" section.
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift:83` · `qa: SETUP-11`
- **STP-012** When encryption is offered (developer build) and a folder is chosen, the setup sheet recommends it and offers a "Set Up Encryption" button, which does not block Finish setup.
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift:164` · `qa: SETUP-11`
- **STP-013** When the user presses Finish setup, setup is marked complete and does not appear again on later launches while the terms version is unchanged.
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift, Sources/App/Services/AppSettings.swift` · `qa: SETUP-10`
- **STP-014** When the user later opens Settings → General → Status, they can see the health of each item as OK, Warning or Problem and can reopen the Setup Assistant.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: SETUP-10`
- **STP-015** When the speech model is missing, Settings → AI and models offers Download for it, with its size and a license link.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:454, Sources/App/Views/Settings/SettingsComponents.swift:28` · `qa: SETUP-09`
- **STP-016** When the current terms have not been accepted, the Terms & Privacy row says "Review and accept the Terms of Service and Privacy Policy." with a "Review" action that opens the Terms of Service.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift` · `qa: SETUP-02`
- **STP-017** In a developer build, the checklist also lists "Calendar (optional)" and "Reminders (optional)" rows that show a warning, not a problem, when not allowed.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift` · `qa: SETUP-11`
- **STP-018** When the terms box is unticked, Finish setup is disabled and the footer says "Accept the Terms of Service and Privacy Policy to continue."
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift` · `qa: SETUP-02`
- **STP-019** When microphone access was denied, its row is a problem and says "Turn this on in System Settings > Privacy & Security > Microphone." with an "Open Settings" action.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift` · `qa: SETUP-07`
- **STP-020** When the microphone has not been decided, the row offers "Allow Microphone", which shows the macOS permission prompt.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift, Sources/App/Views/SetupChecklistView.swift` · `qa: SETUP-07`
- **STP-021** When call-audio access was denied earlier, the Allow action opens System Settings and the row updates within about 30 seconds of the user approving it there.
  `surface: ui` · `evidence: Sources/App/Services/SystemSettingsLinks.swift, Sources/App/Views/SetupChecklistView.swift` · `qa: SETUP-08`
- **STP-022** When the AI model has not been downloaded, its row says "Download the AI model (<name>, about N MB). It runs inside Aletheia on this Mac; nothing else to install."
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift` · `qa: SETUP-09`
- **STP-023** When no folder is chosen, the Data folder row says "No folder chosen yet. Open Settings to pick one." with a "Choose Folder…" action; once chosen, it shows the folder path.
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift` · `qa: SETUP-06`
- **STP-024** When some checklist items are incomplete, the first one with an action is highlighted as the current step.
  `surface: ui` · `evidence: Sources/App/Views/SetupChecklistView.swift` · `qa: SETUP-02`
- **STP-025** When encryption is already on for the chosen folder, the setup sheet says "At-rest encryption is on for this folder."
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift:170` · `qa: SETUP-11`
- **STP-026** When encryption is offered but no folder is chosen, the setup sheet says "Choose a data folder above, then you can turn on at-rest encryption here."
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift:194` · `qa: SETUP-11`
- **STP-027** When the AI model is ready, its row says "<name> is ready, built into Aletheia."
  `surface: ui` · `evidence: Sources/App/Services/ToolHealth.swift` · `qa: SETUP-09`
- **STP-028** When the terms version changes after setup was finished, the setup sheet returns until the new terms are accepted, and every acceptance is kept with its date in the data folder.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift, Sources/App/Services/Legal.swift` · `qa: SETUP-12`

## Settings (SET)

- **SET-001** When the user opens Settings, a sidebar lists General, AI and models, Formats, Backups, Privacy & Security, License key and Licenses & Legal, and Set-aside recordings only when there are some.
  `surface: ui` · `evidence: Sources/App/Views/Settings/SettingsComponents.swift:9, Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-01`
- **SET-002** When the user reopens Settings, it opens to the pane last used, and Up and Down arrow keys move between panes.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Views/Settings/SettingsComponents.swift:119` · `qa: SETTINGS-01`
- **SET-003** In General, the data folder shows its path (or "Not chosen yet") with Choose… and Show in Finder, and the caption "Everything lives here. Changing it moves nothing; point it at an existing Aletheia folder to switch."
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-02`
- **SET-004** When the app is relaunched, the chosen data folder is still in use.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift:483` · `qa: SETTINGS-02`
- **SET-005** On a fresh install, raw audio is not kept after transcription.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:435` · `qa: SETTINGS-04`
- **SET-006** When the user selects Light, System or Dark under Appearance, the whole app (windows, sheets and menus) changes at once.
  `surface: ui` · `evidence: Sources/App/Views/Theme/AppearancePreference.swift, Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-03`
- **SET-007** On a fresh install, the app lock is on.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:444` · `qa: LOCK-01`
- **SET-008** On a fresh install, summaries are not prepared while the Mac is on battery power.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:473, Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-04`
- **SET-009** When the user opens AI and models, the "Speech recognition" card has one model picker with a chip of Downloading, Installed or Not downloaded, a "Downloaded" mark with "Re-download" when installed, "Not downloaded (~N MB)" with "Download" otherwise, a percent bar while downloading, and a license link.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:454` · `qa: SETTINGS-05`
- **SET-010** When the user opens AI and models, the "Language model" card shows "In use now", and an "Off" chip saying "Apple Intelligence is turned off on purpose."
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-06`
- **SET-011** When the user opens AI instructions, they can edit the text, and "Reset to Default" restores it and is disabled while the text already is the default.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: NOTE-07`
- **SET-012** When the user manages Risk phrases, they can add a phrase, remove one, and use "Clear All" or "Reset to Defaults", each of which asks for confirmation ("Clear all risk phrases?", "Reset risk phrases?").
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AppSettings.swift:293` · `qa: SETTINGS-09`
- **SET-013** When the user opens Formats, they can set the default progress note format and the summary length, and turn on or off comments in drafts, patient background and preparing summaries on battery.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-10`
- **SET-014** When the user opens Backups, the pane shows "Keep my data out of Time Machine & iCloud backups" (on by default) and the caption "Before a database schema change or an encryption change, Aletheia saves a safety copy of the database in a hidden .backups folder inside your data folder."
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/BackupExclusion.swift, Sources/App/Services/Store.swift:386` · `qa: BACKUP-01`
- **SET-015** When the user turns on "Keep my data out of Time Machine & iCloud backups", the data folder is excluded from those backups now and again on later launches, and an explicit off is respected.
  `surface: background` · `evidence: Sources/App/Services/BackupExclusion.swift, Sources/App/Services/AppSettings.swift:351` · `qa: BACKUP-02`
- **SET-016** When the user opens General → Status, they can toggle "Show recording diagnostics", which is off by default and adds a call-audio readout of permission and stream state to the recording screen.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift, Sources/App/Services/AppSettings.swift:442` · `qa: SETTINGS-11`
- **SET-017** When the user opens Licenses & Legal, the app shows the bundled third-party notices as read-only text with links, or "The license notices are missing from this build."
  `surface: ui` · `evidence: Sources/App/Views/Settings/LicensesPane.swift, Sources/App/Services/ThirdPartyNotices.swift` · `qa: SETTINGS-12`
- **SET-018** When "Show patient names in notifications" is left at its default, it is off.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:461` · `qa: NOTIFY-06`
- **SET-019** When General is shown in a production build, no Spotlight option appears.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:208` · `qa: SEARCH-12`
- **SET-020** When the user opens Licenses & Legal, the Terms of Use and Privacy Policy links open the copies bundled in the app, a "Consent Guide…" button opens the guide, and an "Accepted" row shows "v<version> on <date, time>" only when the current terms are accepted.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:326, Sources/App/Services/Legal.swift` · `qa: SETTINGS-12`
- **SET-021** When the Settings window is shown, its minimum size is 900 by 640 points.
  `surface: ui` · `evidence: Sources/App/Views/Settings/SettingsComponents.swift:88` · `qa: SETTINGS-01`
- **SET-022** When the user looks for an encrypted local or iCloud backup, Settings has no such control; stored preferences for those backups change nothing.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift:313, Sources/App/Views/SettingsView.swift` · `qa: BACKUP-01`
- **SET-023** When the built-in llama.cpp engine is built into the app, AI and models shows the "Built-in model (llama.cpp)" card in every tier, including production.
  `surface: ui` · `evidence: Sources/App/Services/Llama/EmbeddedLlamaFeatureModule.swift:21, Sources/App/Views/SettingsView.swift` · `qa: SETTINGS-06`
- **SET-024** On a fresh install, transcription starts automatically when a recording ends.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:504` · `qa: SETTINGS-04`
- **SET-025** On a fresh install, Appearance is Dark.
  `surface: invariant` · `evidence: Sources/App/Views/Theme/AppearancePreference.swift:15` · `qa: SETTINGS-03`
- **SET-026** When the user relaunches the app, the chosen Appearance is still applied.
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift:437, Sources/App/AletheiaApp.swift:28` · `qa: SETTINGS-03`
- **SET-027** On a fresh install, the app locks after 15 minutes of inactivity.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:63` · `qa: SETTINGS-04`
- **SET-028** On a fresh install, the app does not lock when Aletheia is hidden.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:445` · `qa: SETTINGS-04`
- **SET-029** On a fresh install, Aletheia is hidden from screen sharing.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:446` · `qa: SETTINGS-04`
- **SET-030** On a fresh install, comments are included when drafting notes.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:460` · `qa: SETTINGS-04`
- **SET-031** On a fresh install, the patient's background is provided to the assistant.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:465` · `qa: SETTINGS-04`
- **SET-032** On a fresh install, the default progress note format is a plain summary.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift:456` · `qa: SETTINGS-04`
- **SET-033** When Aletheia Doctor is in the build, General → Status offers "Aletheia Doctor…".
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: SECURITY-07`
- **SET-035** On a fresh install, automatic update checks are on and run on launch and when switching back to the app.
  `surface: background` · `evidence: Sources/App/Services/AppSettings.swift:477, Sources/App/AletheiaApp.swift` · `qa: UPDATE-01`
- **SET-036** When the user presses "Check for updates", the row shows "You're up to date (checked at …)", "Couldn't check for updates" or "v<version> available", with a "View Releases on GitHub" link.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: UPDATE-02`
- **SET-037** When a preview or developer build shows "Find patients in Spotlight", its caption says only initials and dates are indexed, never names, transcripts or summaries, and results are removed while Aletheia is locked.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:211` · `qa: SEARCH-12`
- **SET-038** When the build offers encryption, "Keep raw audio after transcription" is shown and is disabled until encryption is on; otherwise it is not shown.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:187, Sources/App/Views/Settings/SettingsComponents.swift:75` · `qa: TRANSCRIBE-12`
- **SET-039** In the "Built-in model (llama.cpp)" card, "Remove <name>" appears for each downloaded model not currently selected.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift:564` · `qa: SETTINGS-08`
- **SET-040** In Backups, "Show backups folder in Finder" opens the hidden backups folder, or the data folder when no backups exist, and is disabled with no data folder.
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: BACKUP-03`
- **SET-041** In Backups, the Time Machine banner says "Your data folder is kept out of Time Machine and iCloud backups. Aletheia does not make its own backup copies yet, so keep a copy of your own." when the toggle is on, and otherwise "Aletheia does not make its own backup copies yet. Time Machine includes the data folder by default."
  `surface: ui` · `evidence: Sources/App/Views/SettingsView.swift` · `qa: BACKUP-01`
- **SET-042** When the user chooses a data folder that syncs with iCloud, is managed by a third-party cloud service, is a network folder or is on an unencrypted removable disk, the choice is refused with "This folder syncs with iCloud. Choose a folder that stays on this Mac.", "This folder is managed by <provider>. Choose a folder that stays on this Mac.", "Network folders cannot hold Aletheia data. Choose a folder on this Mac." or "This removable disk is not encrypted. Choose an encrypted local disk." as it applies, and the data folder is unchanged.
  `surface: ui` · `evidence: Sources/App/Services/DataFolderPolicy.swift:29-37, Sources/App/Services/AppSettings.swift:510-513` · `qa: SETTINGS-13`
- **SET-043** When Aletheia opens and its saved data folder no longer passes that check, a "Move data to this Mac" sheet opens over the main window, and while the app is locked it stays hidden and shows again after unlock.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift:199-211, Sources/App/Services/DataFolderPolicy.swift:86-88, Sources/App/Views/DataFolderMoveView.swift:17` · `qa: SETTINGS-14`
- **SET-044** In the "Move data to this Mac" sheet, the user sees the current folder and "Destination: <path>" (the standard local folder unless "Choose another local destination…" picks a folder, which gets a new "Aletheia Data" subfolder), and "Copy and verify data" copies everything, checks each file against the original and only then switches to the copy while the original stays in place.
  `surface: ui` · `evidence: Sources/App/Views/DataFolderMoveView.swift:28-45, Sources/App/Services/DataFolderMove.swift:22-52` · `qa: SETTINGS-14`
- **SET-045** When a move cannot go ahead, the sheet shows "The destination data folder already contains files. Choose another local folder.", "The data folder contains a symbolic link. Remove it before moving the folder.", "The copied files did not verify. The original folder remains unchanged." or "Choose a destination outside the original folder.", and the original folder is left as it was.
  `surface: ui` · `evidence: Sources/App/Services/DataFolderMove.swift:5-20, Sources/App/Views/DataFolderMoveView.swift:96-99` · `qa: SETTINGS-14`
- **SET-046** When the copy has been verified, the sheet says "The copy was verified and Aletheia now uses the standard local folder. Copies already synced to a cloud service must also be removed there and on other devices." with "Keep original for now" and "Delete original folder…", and deleting asks "Delete the original folder?" first.
  `surface: ui` · `evidence: Sources/App/Views/DataFolderMoveView.swift:20-25, Sources/App/Views/DataFolderMoveView.swift:58-63` · `qa: SETTINGS-14`
- **SET-047** On a fresh install, "Keep my data out of Time Machine & iCloud backups" is on.
  `surface: invariant` · `evidence: Sources/App/Services/AppSettings.swift` · `qa: SETTINGS-04`

## Appearance, accessibility & shortcuts (UX)

- **UX-001** When the user presses Cmd+F, the global search box in the sidebar gets focus, even from inside a transcript or note.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:10` · `qa: SEARCH-01`
- **UX-002** When the user presses Option+Cmd+F, the find bar opens in the transcript or note that has the cursor.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift` · `qa: SEARCH-01`
- **UX-003** When the user presses Cmd+N, a new patient is added.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:12` · `qa: PATIENT-02`
- **UX-004** When the user presses Cmd+B or Cmd+I in the note editor, the selection becomes bold or italic.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:24` · `qa: NOTE-11`
- **UX-005** When the user opens the Keyboard Shortcuts window, it lists three groups: Patients and sessions, Writing a note, and Windows.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift, Sources/App/Views/ShortcutsView.swift` · `qa: MENUBAR-10`
- **UX-006** When the user presses Cmd+W, the front window closes, including Settings, Doctor and the main window.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift:235` · `qa: MENUBAR-11`
- **UX-007** When the user opens the File menu, it has no "New" item.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift` · `qa: MENUBAR-11`
- **UX-008** When the window is resized, the main window cannot shrink below 900 by 600 points.
  `surface: ui` · `evidence: Sources/App/AletheiaApp.swift` · `qa: MENUBAR-10`
- **UX-009** When macOS Writing Tools would apply to patient text fields, they stay off in every window.
  `surface: invariant` · `evidence: Sources/App/AletheiaApp.swift, CLAUDE.md` · `qa: LOCK-08`
- **UX-010** When Increase Contrast is on, the app uses the high-contrast variants of its colors in light and dark.
  `surface: ui` · `evidence: Sources/App/Views/Theme/Theme.swift:129, scripts/check-theme-colors.sh` · `qa: SETTINGS-03`
- **UX-011** When an export finishes, VoiceOver announces "Export ready".
  `surface: ui` · `evidence: Sources/App/Views/ExportStatusToast.swift:65` · `qa: EXPORT-03`
- **UX-012** When the pointer rests for two seconds on a control that has a help tip, a "how this works" popover appears once, and afterwards the text shows as an ordinary tooltip.
  `surface: ui` · `evidence: Sources/App/Views/HoverTip.swift:153` · `qa: MENUBAR-13`
- **UX-013** When a Quit happens with work running, the app waits for it to wind down but no longer than a fixed deadline, shows no alert, and saves interrupted work for the next launch.
  `surface: background` · `evidence: Sources/App/AletheiaApp.swift:32` · `qa: MENUBAR-14`
- **UX-014** When the user presses Cmd+S, edits are saved.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:15` · `qa: MENUBAR-11`
- **UX-015** When the user presses Cmd+G, the note is generated or regenerated.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:16` · `qa: MENUBAR-11`
- **UX-016** When the user presses Cmd+Return, the comment being written is saved.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:14` · `qa: MENUBAR-11`
- **UX-017** When the user presses Shift+Cmd+7 or Shift+Cmd+9 in the note editor, the line becomes a bulleted or numbered list.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:26` · `qa: NOTE-11`
- **UX-018** When the user presses Shift+Cmd+B, Shift+Cmd+H or Shift+Cmd+J in the note editor, the line becomes body text, a heading or a subheading.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:28` · `qa: NOTE-11`
- **UX-019** When an export does not finish, VoiceOver announces "Export didn't finish".
  `surface: ui` · `evidence: Sources/App/Views/ExportStatusToast.swift:84` · `qa: EXPORT-04`
- **UX-020** While an export runs, its progress is exposed to VoiceOver as a label such as "Exporting records, N percent", not as a spoken announcement.
  `surface: ui` · `evidence: Sources/App/Views/ExportStatusToast.swift` · `qa: EXPORT-03`
- **UX-021** When the user presses Escape, a sheet or search closes.
  `surface: ui` · `evidence: Sources/App/Services/ShortcutCatalog.swift:62` · `qa: MENUBAR-11`

## Legal & consent (LEG)

- **LEG-001** On first launch, the user must tick "I have read and agree to the Terms of Service and Privacy Policy." before Finish setup is available; the box is already ticked when the current terms were accepted before.
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift, TERMS.md` · `qa: SETUP-04`
- **LEG-002** When the user ticks the terms box, acceptance (version and date) is saved at once and unticking does not undo it; pressing "Finish setup" saves it again with that moment's date, and Settings shows "Accepted: v<version> on <date, time>".
  `surface: ui` · `evidence: Sources/App/Services/AppSettings.swift:563, Sources/App/Views/FirstRunView.swift, Sources/App/Views/SettingsView.swift:326` · `qa: SETTINGS-12`
- **LEG-003** When acceptance is recorded, one line is appended to "legal-acceptance.log" in the data folder with the accepted version, the UTC time and the app version.
  `surface: invariant` · `evidence: Sources/App/Services/LegalReceipt.swift, TERMS.md` · `qa: BUILD-12`
- **LEG-004** When no data folder exists yet, no acceptance log is written and setup still proceeds.
  `surface: invariant` · `evidence: Sources/App/Services/LegalReceipt.swift:27` · `qa: BUILD-12`
- **LEG-005** When the terms version changes (the current one is 2026-10-23), the setup sheet reappears on next launch until the new terms are accepted.
  `surface: ui` · `evidence: Sources/App/Services/Legal.swift, Sources/App/AletheiaApp.swift` · `qa: SETUP-04`
- **LEG-006** When an older, empty or missing accepted version is stored, the app counts the terms as not accepted.
  `surface: invariant` · `evidence: Sources/App/Services/Legal.swift:30` · `qa: SETUP-04`
- **LEG-007** When the user taps Terms of Use or Privacy Policy, the bundled documents open in the app and read without internet access.
  `surface: ui` · `evidence: Sources/App/Services/Legal.swift, Sources/App/Views/FirstRunView.swift` · `qa: SETUP-03`
- **LEG-008** The setup footer says "Aletheia is a tool, not legal or clinical advice. Get your client's consent before recording, and follow your licensing board's rules."
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift` · `qa: SETUP-04`
- **LEG-009** The setup sheet says "Before using Aletheia, please review and accept the terms. Your acceptance is recorded on this Mac and is never sent anywhere."
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift, TERMS.md` · `qa: SETUP-01`
- **LEG-010** The Privacy and Terms documents are dated 2026-10-23, the same version the app asks users to accept.
  `surface: invariant` · `evidence: PRIVACY.md:3, TERMS.md:3, Sources/App/Services/Legal.swift:19` · `qa: SETUP-03`
- **LEG-011** When the terms version has changed after setup was completed, ticking the terms box alone dismisses the setup sheet.
  `surface: ui` · `evidence: Sources/App/Views/FirstRunView.swift, Sources/App/AletheiaApp.swift` · `qa: SETUP-04`

## Build tiers (BLD)

- **BLD-001** When the app is built for release, it ships the production tier with no developer or preview feature compiled in.
  `surface: invariant` · `evidence: project.yml, Sources/App/Services/Features/BuildTier.swift` · `qa: BUILD-06`
- **BLD-002** When the app is built for development (Debug), it includes preview and developer features.
  `surface: invariant` · `evidence: project.yml:25, Sources/App/Services/Features/BuildTier.swift` · `qa: BUILD-04`
- **BLD-003** When an override of the tier is set in a Release build, it is ignored.
  `surface: invariant` · `evidence: Sources/App/Services/Features/BuildTier.swift:64` · `qa: BUILD-04`
- **BLD-004** The production build includes the Doctor health check, source citations and the built-in AI model.
  `surface: invariant` · `evidence: Sources/App/Services/Features/FeatureRegistry.swift, Sources/App/Services/Llama/EmbeddedLlamaFeatureModule.swift:21` · `qa: BUILD-06`
- **BLD-005** The preview tier adds Spotlight, medications and suggested questions to production, and is reachable only through an override in a Debug build, since no separate preview configuration exists.
  `surface: invariant` · `evidence: Sources/App/Services/Features/FeatureRegistry.swift, project.yml:24, Sources/App/Services/Features/BuildTier.swift:64` · `qa: BUILD-06`
- **BLD-006** The developer build adds at-rest encryption, Calendar and Reminders scheduling, and Siri and Shortcuts.
  `surface: invariant` · `evidence: Sources/App/Services/Features/FeatureRegistry.swift, README.md:162` · `qa: BUILD-06`
- **BLD-007** The production app's signed entitlements are sandbox, microphone and user-selected file access only.
  `surface: invariant` · `evidence: Sources/App/Resources/Aletheia.entitlements, scripts/check-entitlements.sh` · `qa: BUILD-01`
- **BLD-008** The production app's Info.plist contains no Calendar or Reminders purpose strings, while the developer build's carries them.
  `surface: invariant` · `evidence: Sources/App/Resources/Info.plist, scripts/check-entitlements.sh` · `qa: BUILD-03`
- **BLD-009** The production build has hardened runtime on.
  `surface: invariant` · `evidence: project.yml:35` · `qa: BUILD-01`
- **BLD-010** The production app's executable contains no debug-only harness flags.
  `surface: invariant` · `evidence: scripts/check-entitlements.sh` · `qa: BUILD-04`
- **BLD-011** The built-in AI model and speech runtime are bundled in the app and verified, with no external AI server or separate install.
  `surface: invariant` · `evidence: scripts/verify-bundled-assets.sh, scripts/check-runtime-pins.sh, README.md` · `qa: BUILD-05`
- **BLD-012** The app bundles a network helper service embedded inside it.
  `surface: invariant` · `evidence: project.yml, Sources/NetworkHelper` · `qa: BUILD-02`
- **BLD-013** When the user opens Settings, the app shows its current version, taken from the build's release metadata.
  `surface: ui` · `evidence: Sources/App/Resources/Info.plist, Sources/App/Views/SettingsView.swift` · `qa: BUILD-03`
- **BLD-014** The developer build's entitlements add calendar access to the production set.
  `surface: invariant` · `evidence: Sources/App/Resources/AletheiaDev.entitlements, scripts/check-entitlements.sh` · `qa: BUILD-01`
- **BLD-015** The app requires macOS 14 or later.
  `surface: invariant` · `evidence: project.yml:11, Sources/App/Resources/Info.plist` · `qa: BUILD-03`
- **BLD-016** The network helper's entitlements are sandbox and outgoing network access only.
  `surface: invariant` · `evidence: project.yml, scripts/check-entitlements.sh` · `qa: BUILD-02`
- **BLD-017** Microphone and Speech-recognition purpose strings are present in every build.
  `surface: invariant` · `evidence: Sources/App/Resources/Info.plist` · `qa: BUILD-03`
