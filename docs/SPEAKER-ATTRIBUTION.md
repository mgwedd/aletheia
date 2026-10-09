# Speaker attribution: how lines get labelled, where it breaks, what to do

Analysis for issue #173. Nothing here has been verified on a real two-party
call; claims about audio behaviour are marked **unverified**. Line numbers are
against `main` at the time of writing.

## TL;DR

- There is **no voice analysis**. The label is the **audio track** the line came
  from: `mic.caf` becomes "Therapist", `call.caf` becomes "Call audio".
- That is correct only when (a) the patient is actually on the call track and
  (b) nothing from the call leaks into the mic. Neither is verified.
- It is **wrong by construction** for in-person or shared-mic sessions: every
  line is "Therapist".
- The AI prompts never mention the labels, so the model is never told that
  "Call audio" is the patient, nor that the labels can be wrong.

## Data flow

```
 therapist voice ──► [mic] AVAudioEngine input tap ───────────► mic.caf
                      MicRecorder.swift:289-294                  (mono, device rate)
                      plain tap, no echo cancellation
                                  ▲
                                  │ BLEED (speakers): patient audio re-enters the mic
                                  │
 patient voice ─► call app ─► Mac speakers/headphones
                                  │
                                  └► [call] ScreenCaptureKit, whole-display system audio
                                      SystemAudioCapture.swift:130-140   ► call.caf
                                      excludes only Aletheia's own audio    (48k stereo)
                                      (:135); file created lazily on
                                      first buffer (:167)

 SessionDetailView.transcribe() :668-676   (decrypts temp copies, passes both URLs)
   │
   ▼
 WhisperTranscriber.transcribeSession()                      WhisperTranscriber.swift:35-74
   ├─ tracks = [mic→"Therapist" (:46), call→"Call audio" (:49)]   only files that exist
   ├─ per track: resample → skip if whole-file RMS ≤ 0.002 (:79) → Whisper → TranscribedLine(source:)  (:93)
   ├─ TranscriptCleaner.clean()  per source (:64)  drop [BLANK_AUDIO] etc, coalesce lines
   │                                                 starting ≤2 s apart (TranscriptCleaner.swift:103-119)
   ├─ lines.sort { startTime }                      (:67)   ← the only "diarization": a time sort
   └─ "[MM:SS] <source>: <text>"                    (:68-73)
   │
   ▼
 transcript text ──► saved ──► Prompts.* (summarize / progressNote / sessionChat / patientChat)
                               no speaker-label legend in any of them
```

`TranscribedLine.source` (`TranscriptCleaner.swift:4-8`) is a free `String`. It
is set at exactly one place, `WhisperTranscriber.swift:93`, from the track label.
Nothing downstream parses it back (the views do not reference the labels; only
`TranscriptTimeline` reads the `[MM:SS]` prefix).

## Failure modes

| # | Situation | What happens | Code |
|---|---|---|---|
| F1 | **Speaker bleed.** Patient plays through speakers; mic hears them. | Same words transcribed on both tracks. The mic copy is labelled "Therapist", so the patient's speech appears as the therapist's, usually a few hundred ms to seconds off the true copy. Worst case for clinical attribution. | `MicRecorder.swift:289-294` plain `installTap`, no voice processing; `WhisperTranscriber.swift:46` unconditional label |
| F2 | **In-person / shared mic.** Both people on the mic; call track silent (the 2.4.4 test). | Every line is "Therapist", including the patient's. Labels are "correct for the input" but wrong about the people. | `WhisperTranscriber.swift:46,79` (silent call track skipped, no other label) |
| F3 | **Only one track has audio** (system audio failed or was denied). | Session continues mic-only by design, same output as F2, and nothing in the transcript says the patient was not captured. | `SessionRecorder.swift:85-92` (call failure swallowed into health), `WhisperTranscriber.swift:44-50` |
| F4 | **Call track has non-patient audio.** System audio is whole-display, so notifications, music or a second app's audio land on it. | Labelled "Call audio", indistinguishable from the patient. Aletheia's own audio is excluded; nothing else is. | `SystemAudioCapture.swift:130-135` |
| F5 | **Track clocks disagree.** The call file is created at the first buffer, after `await systemAudio.start`, and each buffer hops through a `Task { @MainActor }`. If ScreenCaptureKit does not emit buffers during silence, the file also loses the silent spans. | The merge-by-time at `:67` interleaves turns wrongly; patient and therapist swap order or drift apart over a long session. **Unverified**: depends on whether SCStream emits silent buffers. | `SystemAudioCapture.swift:167-168,180-186`; `SessionRecorder.swift:85-89`; `WhisperTranscriber.swift:67` |
| F6 | **Whole-file silence gate.** RMS over the entire file at ≤0.002 skips the track. | A soft-spoken patient at low call volume in a long, mostly quiet file could be dropped entirely, then looks like F3. Edge case. | `WhisperTranscriber.swift:79`, `AudioResampler.swift:254-262` |
| F7 | **Bluetooth headset / device swap mid-session.** | Mic input format changes (HFP drops to 16 kHz mono) but the file was opened with the start format; writes can fail and the mic track truncates. Out of scope here but it silently turns a two-track session into a one-track one. | `MicRecorder.swift:289-290,314-332` |
| F8 | **Long monologues / coalescing.** Same-source lines whose starts are ≤2 s apart are merged, and the timestamp is the first segment's. | Not a labelling error, but one label and one timestamp can cover a long turn, and cross-track interruptions inside it are reordered to after it. | `TranscriptCleaner.swift:103-119` |
| F9 | **Prompts do not define the labels.** | `summarize`, `progressNote`, `sessionChat` just say "transcript". `progressNote` asks for "Client reported…". With an F2 transcript the model sees only "Therapist:" lines and may attribute the patient's statements to the clinician, or report "Not documented". `patientChat` only says "timestamped lines are the session transcript". `formatHistory` uses "Therapist" for the chat user, a second, unrelated use of that word in the same prompt. | `Prompts.swift:39-52,90,160-186,193` |

Residual mismatch: `Transcribing.swift:14-15` promises a "speaker-labeled
transcript"; what it provides is a track-labeled one.

## Answers to the issue's questions

1. **Patient on the call track?** By design yes: ScreenCaptureKit captures what
   the Mac outputs, which is the remote party in Zoom/Tebra/FaceTime. Whether it
   holds for headphones vs speakers, and for each call app, is **unverified**.
2. **Leakage?** Yes, structurally possible. The tap is a plain input tap
   (`MicRecorder.swift:294`) with no AEC. With headphones it should be negligible;
   with speakers it is F1. Magnitude **unverified**.
3. **In-person / shared mic?** Track separation cannot do it (F2). Needs
   diarization, enrollment, or manual relabel.

## Options, ranked

Ordered by value for effort and risk; matches the issue's suggested order.

| Rank | Option | Cost | Risk | Notes |
|---|---|---|---|---|
| 1 | **Verify on a real two-party call** (checklist below) | S, no code | none | Gates every choice below; settles F1, F4, F5. |
| 2 | **Manual "swap speakers" / relabel per line or block** | S–M (UI plus a pure text helper) | low | No new dependency, always works, fixes F2 and F3 after the fact. The transcript is already hand-editable (`SessionDetailView.swift:30`), but a bulk relabel changes text offsets, so check how it interacts with margin-comment anchors (`TranscriptHighlighter`). |
| 3 | **Label legend in the prompts** (labels are channel-derived, "Call audio" is normally the client, in a mic-only transcript both people may be "Therapist") | S | low–med | Cheap mitigation for F9. Prompt wording changes model output everywhere, including any fine-tuned model (`docs/FINETUNING-PIPELINE.md`); retest before shipping. |
| 4 | **Text-level leakage gate** (`SpeakerLeakageFilter`, added in this PR, **unwired**) | S to wire (one call after cleaning, before the sort) | med | Drops a mic line whose words are, in order, ≥80% inside call lines starting within 5 s (min 5 words). Pure Swift, no new dependency. Risk is a false drop deleting real therapist speech, e.g. verbatim reflective listening; thresholds need real audio. Cannot fix F2. |
| 5 | **Energy-based gating** (zero mic frames where call-track energy is high and mic is correlated, before Whisper) | M | med | More robust than text matching and also stops Whisper transcribing the echo, but needs sample-accurate track alignment (F5) and tuning on real audio. |
| 6 | **Apple voice processing / AEC** on the input node | M | med–high | Real echo cancellation at the source. Known hazards to test: changes the input format (the file is opened with the pre-change format, `MicRecorder.swift:289-290`), ducks other audio (the call volume) unless ducking is configured, can clip the therapist during double-talk, and unknown interaction with the SCStream capture. **Unverified** that it references audio played by other processes. |
| 7 | **Whisper tinydiarize (`tdrz`)** | M | med | Turn-change markers only, not identities, so it does not say who is the patient. Needs a different `.en-tdrz` model file (not among the pinned models in `WhisperModelPins.swift`) and SwiftWhisper support that is **unverified**. Low value on its own. |
| 8 | **Voice enrollment + on-device speaker embeddings** | L | high (policy) | Best accuracy and the only route to true F2 separation. Needs a speaker-embedding model: a new pinned download plus a first-party-dependency decision, per the issue. Do not start before that decision. |

Cheap, not in the issue: in a mic-only session, write a neutral label
("Speaker") instead of "Therapist", or add a header line such as "(patient audio
not captured)". Fixes F3's silence but changes fixtures and prompts' implied
vocabulary; see decisions.

## What shipped in this PR

- This document.
- `Sources/App/Services/SpeakerLeakageFilter.swift` plus
  `Tests/AletheiaTests/SpeakerLeakageFilterTests.swift`: option 4 as a pure,
  unit-tested helper. **Not called from anywhere.** The issue lists gating as an
  option and puts it in step 2 of its suggested order, but does not authorise
  changing transcripts before step 1 (real-call verification).
- Comment fix: `SessionRecorder.swift` described the label as "You"; it is
  "Therapist".

To wire it later (after verification), in `WhisperTranscriber.transcribeSession`
keep the cleaned lines per track, run
`SpeakerLeakageFilter.dropLeakedLines(mic:call:)` on the mic lines, then
concatenate and sort. The loop currently appends both tracks into one array
(`:56-65`), so it needs a small restructure.

## Must be verified on a real two-party call

Run each case with the call app the practice actually uses (Zoom, Tebra in a
browser, FaceTime), 2–3 minutes, scripted turns, patient role played by a second
person on another device.

1. **Headphones:** patient speech only on `call.caf`, therapist only on
   `mic.caf`. Listen to both files; check the mic for any patient audio.
2. **Speakers (laptop and external):** how loud is the leak on `mic.caf`, and
   does Whisper transcribe it (F1)? Does the leaked copy start within 5 s of the
   call copy, and with what word overlap? This is the data the leakage gate's
   thresholds need.
3. **Silence behaviour (F5):** do `call.caf` and `mic.caf` have the same duration
   when the patient is silent for 30+ s? Does a spoken marker at a known time
   (clap, or both sides saying "mark") land at the same `[MM:SS]` on both
   tracks? Repeat across a pause/resume.
4. **Call start offset:** time between mic start and first call buffer.
5. **Foreign system audio (F4):** play a notification sound mid-call; confirm it
   lands on the call track.
6. **System audio denied/failing (F3):** the session proceeds mic-only; confirm
   what the user sees and what the transcript says.
7. **Bluetooth headset (F7):** connect mid-session; does `mic.caf` keep
   recording?
8. **In-person (F2):** both speakers on one mic; confirm all lines read
   "Therapist" and decide the labelling policy.
9. **Voice processing (if option 6 is pursued):** with it enabled, is the call
   volume ducked, does the mic format change, does the leak vanish, is the
   therapist clipped on double-talk, and does the SCStream capture still work.
10. **Prompts (if option 3 is pursued):** compare a progress note from a
    mic-only transcript before and after a label legend.

## Decisions for the owner

1. After verification, wire the text gate, go straight to AEC, or both?
2. Mic-only sessions: keep "Therapist" for every line, or label neutrally?
3. Relabel UX: per line, per block, or a whole-session swap?
4. Add a label legend to the prompts (changes output for every format)?
5. Is a speaker-embedding model acceptable under the first-party-dependency
   policy? (Blocks option 8 only.)
