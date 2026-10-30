# Changelog

All notable changes to Aletheia are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and [semantic
versioning](https://semver.org/).

**This file is generated at release time** from the [Conventional
Commit](https://www.conventionalcommits.org/) messages since the previous tag —
don't edit it in pull requests. Write a good commit subject (`feat: …`,
`fix: …`) and the release automation adds the entry for you.

## [2.69.2] - 2026-10-30

### Fixed
- keep the patient list on screen when a record can't be read (#543)
- keep unit test runs from blanking the real app's sidebar (#542)

## [2.69.1] - 2026-10-30

### Fixed
- say where the data folder goes and keep setup open until Finish (#540)
- keep the downloaded model on update and the question when compaction fails (#538)
- say there are no psychotherapy notes before exporting (#534)

## [2.69.0] - 2026-10-29

### Added
- offer experimental Apertus medical model (#537)

## [2.68.0] - 2026-10-28

### Added
- default to curated MedGemma models (#536)

## [2.67.1] - 2026-10-28

### Fixed
- Ask progress, My Notes answers, compaction and notarize log (#532)

## [2.67.0] - 2026-10-28

### Added
- add MedLlama 2 and MedGemma opt-in model downloads (#535)

## [2.66.0] - 2026-10-27

### Added
- offer Import Audio only with a test license (#530)
- import a microphone and call track together (#529)

### Fixed
- ship under the com.astrealabs.aletheia bundle ID (#531)

## [2.65.0] - 2026-10-27

### Added
- configurable recording consent per session (#525)
- import an audio file as a session's recording (#524)

### Fixed
- align terms, privacy, consent and setup with app behaviour before the first beta invite (#528)

## [2.64.0] - 2026-10-27

### Added
- show a newer version as a banner, never an up-to-date alert (#520)
- Get a Key drafts an email to support (#519)
- Dark by default, fewer redundant rows (#518)

### Fixed
- license strip close button, strips off the search field, Settings Done at the bottom, Doctor opens the right Settings pane (#522)
- detect FileVault from Disk Arbitration (#521)
- no dev signing key; every build trusts production keys only (#517)

## [2.63.0] - 2026-10-26

### Added
- offline license check (#441)
- margin comments on generated notes and AI prompt inclusion (#169) (#385)
- sign progress notes; AI drafts stay drafts until signed (#507)
- record views, AI use, copies and instruction changes; fixed-text details (#500)
- require a per-patient consent confirmation before recording (#494)
- keep psychotherapy notes separate from the progress note (#493)
- back up the whole data folder and restore into an empty folder (#496)
- confirm before exporting patient data; name exports by initials (#492)
- warn about record retention when deleting a patient (#491)
- record patient and session creation, edits and deletions (#483)
- record security events and alert on log write failure, repeated failed unlocks and a broken chain (#458)
- show patient initials in notifications and the menu bar unless names are opted in (#461)
- back up now to a local folder; remove the iCloud backup stub (#457)
- change the passphrase from Settings without re-encrypting files (#452)
- report a bug or request a feature from the app (#447)
- fetch the license revocation list (#438)
- export all records to a folder from Settings (#444)
- third-party notices and model licenses (#440)
- tamper-evident append-only audit ledger with user identity (#423)
- move networking into a sandboxed helper; the app has no network access (#422)
- emergency access recovery key for encrypted data (#427)
- verify FileVault and gate new records on it (#416)
- private staging and crash-seal sweep for live recordings (#425)

### Fixed
- make backup exclusion and launch recovery deterministic (#515)
- retry discarding audio at launch after a failed delete (#477)
- update settings on the main thread; keep unit tests off the Keychain (#508)
- name the Backups pane and its Time Machine switch correctly (#480)
- block content, sheets and file panels while locked (#479)
- redact patient names from the diagnostics report (#478)
- show deferred-encryption and mic-restart problems (#476)
- refuse a blank patient name from Return (#475)
- open Aletheia's download page, never a link from the feed (#467)
- don't keep the key on this Mac unless asked (#472)
- write data-folder files owner-only (#474)
- refuse synced folders for the recovery key PDF (#466)
- refuse to load a model file of the wrong size (#469)
- keep recording staging and scratch files out of Time Machine (#463)
- check the audit ledger instead of the old log file (#464)
- ask for Touch ID or the Mac password before weakening protection or exporting (#456)
- keep comment excerpts out of the app's search index (#459)
- keep decrypted temporary files in a private scratch folder (#455)
- accurate activity log caption with detail and paging (#450)
- name patients by initials on system surfaces and honor the lock (#454)
- keep the device and ledger keys out of iCloud Keychain, clearer keychain errors (#453)
- redact ids, folder names, known names and stray paths from the report (#451)
- keep test runs off the login Keychain (#443)
- keep the therapist's words as instructions and tag only record material (#437)
- keep Writing Tools off in the recovery-key and network views (#439)
- bound sealed-file and keystore parsing, normalize passphrases (#431)
- turn off Writing Tools on patient text (#417)
- fail closed when database field sealing fails (#412)
- cover app scenes while locked (#424)
- keep the test host from prompting, taking focus or drawing on screen (#436)
- keep unreadable notes intact, report undeletable audio and damaged records (#435)
- keep a lost keystore locked, enforce a passphrase minimum, throttle unlocks, clear stale plaintext copies (#434)
- harden clipboard writes, build tier override, and Whisper model replacement (#433)
- render model Markdown without clickable links (#429)
- keep encrypted folder locked until explicit unlock (#421)
- use local whisper and llama packages for SwiftPM tests (#418)
- ⌘F home field, smooth chat follow, simpler AI status, export confirmation (#410)

## [2.62.1] - 2026-10-21

### Fixed
- open the AI instructions tip above the section, not over the editor (#409)

## [2.62.0] - 2026-10-21

### Added
- find every word, however common or short (#407)

### Fixed
- drop the search home hint and the risk-phrase example (#408)

## [2.61.1] - 2026-10-21

### Fixed
- roomier sidebar search, clearer search hints, and quieter Settings (#406)

## [2.61.0] - 2026-10-21

### Added
- hold-to-talk voice input in the Ask box, recognized on this Mac (#404)
- show one status line for every model run, and narrate Ask's search from its results (#393)
- open transcript and note hits at the match and flash it (#387)
- show Settings "how this works" asides as hover tips (#391)

### Fixed
- make global search obvious and Cmd-F reliable; keep the sidebar reachable (#403)
- minimal lock screen that relies on the system sheet (#402)
- Return and Enter press the keyboard-focused button (#399)
- one themed multi-line text input with the placeholder on the caret (#397)
- name speakers 'You' and the patient's first name, never Y or C (#396)
- hide the "(overlapping)" label from the rendered transcript (#400)
- open Ask threads at the latest message (#398)
- gentler divider snap, animated collapse, draggable strip, clearer arrow (#395)
- trim export header/disclaimer, format blurbs, chat scope tip, and export menu focus ring (#394)
- send passages not whole transcripts, cap the context, and stop echoing search counts (#389)
- wind work down on quit within a deadline and resume it at launch (#390)

## [2.60.0] - 2026-10-21

### Added
- show one line and a progress bar while a note is generated (#384)
- fill the room kept for missing summaries with those sessions' openings (#374)
- resume inline digest builds from the section cache (#376)
- one search field at the top right for everything (#367)
- add a setting to prepare summaries on battery (#369)
- read a long patient history by zoom level, summaries first, transcripts only where search points (#362)

### Fixed
- make the transcript/comments divider draggable (#386)
- size the Notes format picker's segments to their labels (#383)
- keep the Notes tab's action row within the pane, and focus Export in the export popover (#381)
- clear the Swift 6 sendability and isolation warnings (#377)
- estimate tokens by script so non-Latin text can't overflow the window (#370)
- pressure-test fixes for search, tool loop and long histories (#351)

## [2.59.0] - 2026-10-21

### Added
- PDF, Word and Markdown per note and session; whole-patient export as a background zip; rich-text Copy (#345)

### Fixed
- count every merge round in the build's progress steps (#360)
- keep a merged section's anchor one flat range (#361)
- accept a plain number for a tool call's time or session (#357)
- don't read a month name used as a word as a date filter (#354)
- show the tool-loop planning call the earlier chat turns (#355)
- keep patient names out of notifications by default (#359)
- offer Record and Transcribe only when they can act on the session (#348)
- unlock once per session; re-lock only when the Mac is left (#356)

## [2.58.0] - 2026-10-21

### Added
- shortcut hints from bindings, plus a Keyboard Shortcuts window (#352)
- let text be selected and copied on read-only screens (#343)
- segmented AI effort control and a scrollable input field (#337)
- add an overall progress bar and plain stage wording (#339)
- floating comment button, comments pane only when there are comments, draggable split (#349)

### Fixed
- stop a long note from growing the window past the screen (#341)
- remove the AI draft banner above a note (#344)
- say it stays on this Mac up front, not everywhere (#346)
- omit what this build doesn't offer instead of showing it as unavailable (#340)
- drop the Remembers line above the composer (#342)
- drop Copy Details from the AI engine banner (#336)
- show Save and Discard only when there are edits (#338)
- stop truncating the update prompt's buttons (#333)
- drop the "list updates itself" sentence from the checklist intro (#334)
- make the Doctor's fix buttons do something (#335)

## [2.57.2] - 2026-10-20

### Fixed
- merge a speaker's segments by pause, not start-to-start (#332)

## [2.57.1] - 2026-10-20

### Fixed
- stop clipping the Settings sheet (#331)

## [2.57.0] - 2026-10-20

### Added
- consent guide, terms checklist, open ollama, mermaid errors and styles, and patient meta (#234) (#330)

## [2.56.0] - 2026-10-20

### Added
- delete patient with destructive confirmation and cleanup (#225) (#329)

## [2.55.0] - 2026-10-20

### Added
- per-check fix actions and diagnostic checks (#230) (#328)

## [2.54.0] - 2026-10-20

### Added
- open matched note format or comment and route Spotlight sessions (#233) (#327)

## [2.53.0] - 2026-10-20

### Added
- add recurrence rules and .ics export (#232) (#326)

## [2.52.0] - 2026-10-20

### Added
- add review/dismiss for damaged records, retry/folder picker for database, and model name for transcription (#231) (#325)

## [2.51.0] - 2026-10-19

### Added
- note format toggles for comments in drafts and patient background (#227) (#324)

## [2.50.0] - 2026-10-19

### Added
- show lock reason, password fallback, and audit failed unlocks (#323)

## [2.49.0] - 2026-10-19

### Added
- add auto-check toggle, check feedback, and release link (#322)

## [2.48.1] - 2026-10-19

### Fixed
- address remaining review findings (#264) (#321)

## [2.48.0] - 2026-10-19

### Added
- local tool loop, month-merged digests, effort UI, and built-in e2e tests (#286, #318) (#320)

## [2.47.0] - 2026-10-19

### Added
- harden built-in llama.cpp stats, sampling, GBNF notes, remedies, and downloads (#318) (#319)

## [2.46.0] - 2026-10-17

### Added
- make the built-in model the default AI engine in every build (#317)

## [2.45.0] - 2026-10-14

### Added
- size the context to the transcript; flash attention and q8 KV cache (#313)

## [2.44.1] - 2026-10-14

### Fixed
- apply the model's chat template before decoding (#312)

## [2.44.0] - 2026-10-14

### Added
- offer Llama 3.1 8B and Gemma 4 E2B with pinned checksums (#311)
- link llama.cpp b11149 xcframework and compile the embedded engine (#310)
- persistent SQLite FTS5 index replaces the in-memory search cache (#304)

### Fixed
- don't abort when mlx_lm prints no summary (#309)
- review fixes for long-session notes; risk phrases are user settings (#306)

## [2.43.2] - 2026-10-14

### Fixed
- follow-ups to the local LLM eval script (#305)

## [2.43.1] - 2026-10-14

### Fixed
- accurate "newest" coverage label (#300)

## [2.43.0] - 2026-10-14

### Added
- long-session notes from digest plus transcript passages (#299)
- per-model speed history in SQLite, time left while writing (#298)

### Fixed
- tag overlap only when talk-over is real, draw the tag faintly (#302)
- no background Touch ID prompt, idle lock off by default, menu bar focus, Ollama residency (#301)
- compact transcripts before they enter a prompt (#297)

## [2.42.0] - 2026-10-14

### Added
- in-memory search and honest coverage for all-session chat (#290)

### Fixed
- stable num_ctx, keep_alive, warm-up and unload, low temperature (#296)
- plainer coverage wording, one unreadable notice, spinner on searching (#295)
- don't refill the cache from a search that spans a lock (#293)
- follow-ups to digests and context budget (#287, #288) (#291)

## [2.41.0] - 2026-10-14

### Added
- live progress, per-Mac context budget and truncation tripwire (#288)
- anchored section and session digests, built in the background (#287)

## [2.40.0] - 2026-10-14

### Added
- length menu, prompt editor, progress and copy feedback in the note bar (#285)
- compact long conversations instead of silently forgetting them (#284)

### Fixed
- give the composer's caption its own line and quote only the words (#282)
- stop re-locking when switching to another app (#281)
- size the context window to the prompt (#283)

## [2.39.0] - 2026-10-14

### Added
- skip silence with whisper.cpp's Silero VAD (#279)
- whisper.cpp v1.9.5 with Metal for all builds, drop SwiftWhisper (#278)

## [2.38.0] - 2026-10-14

### Added
- transcribe automatically after recording, queue and explain blocked actions (#277)

## [2.37.2] - 2026-10-12

### Fixed
- drop speaker echo from the mic track and label it "You" (#276)

## [2.37.1] - 2026-10-12

### Fixed
- log system audio capture start, stop and stream errors (#274)

## [2.37.0] - 2026-10-12

### Added
- show why call audio is off, with an optional diagnostics readout (#271)

## [2.36.5] - 2026-10-12

### Fixed
- try call audio once per launch when access isn't confirmed (#270)

## [2.36.4] - 2026-10-12

### Fixed
- only ask for call audio in setup; remember a confirmed grant (#269)

## [2.36.3] - 2026-10-12

### Fixed
- keep the mic track going when the input device changes format (#266)
- ask for call audio at most once per launch when access isn't confirmed (#267)
- single-flight app unlock, drop dead permissionError, correct elapsed doc (#268)
- judge silence per second and keep the loudest channel (#265)

## [2.36.2] - 2026-10-12

### Fixed
- keep the question when recovery is cancelled; retry every failed request (#263)

## [2.36.1] - 2026-10-12

### Fixed
- convert the pre-migration JSON copies when encryption changes (#262)

## [2.36.0] - 2026-10-12

### Added
- focus the clicked field in the editor with the caret at the end (#251)

### Fixed
- one-click recovery when the local AI engine is down or missing its model (#255)
- ask ScreenCaptureKit once per Record, not twice (#260)
- warn when the call track stays silent (#259)
- include patient and session JSON in the pre-migration image (#258)

## [2.35.0] - 2026-10-10

### Added
- open the patient-wide chat in its own resizable window (#253)
- ship source citations in production (#249)

## [2.34.2] - 2026-10-10

### Fixed
- match backup toggles and audit log copy to what the app does (#248)
- explicit File > Close Window (⌘W) command (#242)

## [2.34.1] - 2026-10-10

### Fixed
- stop the screen-recording prompt loop and the status list jitter (#241)
- record an entry when a session or patient history export is saved (#240)
- stop the elapsed clock while paused (#236)

## [2.34.0] - 2026-10-10

### Added
- open the editor with a single click on a profile field (#235)
- inline comment composer, schedule sheet and menu-bar panel redesign (#224)
- redesign first-launch checklist and Mermaid diagram card (#223)
- restyle Edit patient and encryption setup/unlock to the artboards (#222)
- redesign the Doctor window to the artboard (#221)
- sidebar layout with General, AI, Note format, Encryption, Backups and Security panes (#220)
- restyle transcription, damaged-records, database, lock and update screens to the artboards (#219)
- flat global search with filters and keyboard navigation (#218)

## [2.33.0] - 2026-10-09

### Added
- status tokens and kit pieces for the new artboards (#217)

## [2.32.0] - 2026-10-09

### Added
- formatted editor for My Notes and note edits (#215)
- Concise / Natural / Detailed summary length (#214)

### Fixed
- drop the "On this Mac only" footer (#213)
- readable paragraphs and labels in generated notes (#212)

## [2.31.0] - 2026-10-09

### Added
- Doctor, update prompt and search use theme colors (#208)

## [2.30.0] - 2026-10-09

### Added
- Settings panes use theme colors (#210)
- banners, lock screen and patient editor use theme colors (#209)
- Mermaid diagrams use theme colors (#207)
- live input level meters on the recording panel (#205)
- serif typography for the generated note (#204)

## [2.29.0] - 2026-10-09

### Added
- setup checklist and first-run screen on the new design (#202)
- recording panel and menu bar on the new design (#201)
- Ask chat on the new design (#200)
- patient sidebar and patient column on the new design (#199)
- session screen on the new design (#198)
- asset-catalog palette, Light/Dark/System setting, control kit (#196)

## [2.28.0] - 2026-10-09

### Added
- edit a comment from its card in the margin rail (#195)
- profile card and Edit sheet, editable name, one Notes tab, styled text boxes (#193)

### Fixed
- close the update prompt when the download starts (#194)

## [2.27.2] - 2026-10-09

### Fixed
- fix session list empty-click layout (#192)

## [2.27.1] - 2026-10-09

### Fixed
- draw diagrams only when the question asks for one (#191)

## [2.27.0] - 2026-10-09

### Added
- edit the transcript in place; flag generated notes as outdated (#186)
- keep interjections in place and mark overlapping speech (#188)
- add unwired SpeakerLeakageFilter and document speaker labelling in code (#184)
- edit generated notes in place, keep edits across regenerate (#187)

### Fixed
- show progress card, add real cancel, keep state across navigation (#185)
- opening a session no longer writes its note (#181)
- keep "- " turn markers from being coalesced away (#180)

## [2.26.1] - 2026-10-09

### Fixed
- include notes and comments in patient-wide chat and surface unreadable transcripts (#178)

## [2.26.0] - 2026-10-09

### Added
- queue generation requests and show when the model is busy (#177)

## [2.25.1] - 2026-10-09

### Fixed
- anchor transcript comments by position, not just quoted text (#176)

## [2.25.0] - 2026-10-09

### Added
- render Mermaid diagrams natively (#167)
- keep a separate progress note per format (#166)

## [2.25.0] - 2026-10-09

### Added
- keep a separate progress note per format (#166)

## [2.24.2] - 2026-10-09

### Fixed
- stop stale snapshots overwriting notes and keep the session list visible (#165)

## [2.24.1] - 2026-10-09

### Fixed
- drop non-speech tags and skip silent tracks (#163)

## [2.24.0] - 2026-10-01

### Added
- add root Package.swift for fast swift test iteration (#103) (#159)

## [2.23.0] - 2026-10-01

### Added
- continuous crash-safe header flushing and mic-routing fallback (#127) (#158)

## [2.22.0] - 2026-09-30

### Added
- diagnose an unopenable database and add Aletheia Doctor (#157)

## [2.21.11] - 2026-09-30

### Fixed
- keep the audio when the transcript is blank (#153)

## [2.21.10] - 2026-09-30

### Fixed
- fail loud on an unreadable session.json or patient.json (#154)

## [2.21.9] - 2026-09-30

### Fixed
- include the data folder in Time Machine by default (#152)

## [2.21.8] - 2026-09-30

### Fixed
- stop reporting an encrypted backup that nothing writes (#150)

## [2.21.7] - 2026-09-30

### Fixed
- drop the plaintext pre-image after enabling encryption (#148)

## [2.21.6] - 2026-09-30

### Fixed
- mandatory SHA-256 pins and commit-locked downloads for Whisper models (#145)

## [2.21.5] - 2026-09-30

### Fixed
- don't leave plaintext temp copies when a decrypt fails (#149)

## [2.21.4] - 2026-09-30

### Fixed
- convert same-day second sessions when toggling encryption (#147)

## [2.21.3] - 2026-09-30

### Fixed
- drop calendars entitlement from production builds (#146)

## [2.21.2] - 2026-09-25

### Fixed
- stop screen-recording grant from freezing the setup wizard (#141)

## [2.21.1] - 2026-09-25

### Fixed
- launch Ollama when installed but not running (#140)

## [2.21.0] - 2026-09-25

### Added
- real llama.cpp engine for the embedded local-LLM seam (#139)

## [2.20.0] - 2026-09-25

### Added
- swappable LoRA / fine-tuned adapter seam (fails closed on base mismatch) (#137)

## [2.19.0] - 2026-09-24

### Added
- model-download seam so the distribution source is swappable (#136)

## [2.18.0] - 2026-09-24

### Added
- make mic recording fail loud and detect input-device changes (#135)

## [2.17.1] - 2026-09-24

### Fixed
- stop xcodegen from overwriting Info.plist and entitlements (#105)

## [2.17.0] - 2026-09-24

### Added
- GBNF grammar-constrained decoding for structured notes + GIRP format (#133)

## [2.16.0] - 2026-09-24

### Added
- encapsulate the local-LLM engine seam (lifecycle + inference contract) (#130)

## [2.15.0] - 2026-09-24

### Added
- compile-time build tiers; exclude App Intents from the production binary (#120)

## [2.14.0] - 2026-09-24

### Added
- gate patient medications table behind a preview-tier feature module (#117)

## [2.13.0] - 2026-09-24

### Added
- gate source citations behind a preview-tier feature module (#116)

## [2.12.0] - 2026-09-24

### Added
- gate chat suggested questions behind a preview-tier feature module (#115)

## [2.11.0] - 2026-09-24

### Added
- gate embedded llama.cpp ("Built-in Model") behind a dev-only feature module (#114)

## [2.10.1] - 2026-09-24

### Fixed
- read backup-exclusion flag fresh, not from a stale URL cache (#118)

## [2.10.0] - 2026-09-24

### Added
- gate EventKit reminders & calendar behind a dev-only feature module (#113)

## [2.9.0] - 2026-09-23

### Added
- gate at-rest encryption behind a dev-only feature module (#106)

## [2.8.0] - 2026-09-23

### Added
- introduce compile-time feature-module composition seam (#101)

## [2.7.0] - 2026-09-20

### Added
- snapshot the database before a data-transforming migration (#93)

## [2.6.0] - 2026-09-19

### Added
- consistent snapshot-before-seal for encrypted backups (#97)

## [2.5.0] - 2026-09-19

### Added
- versioned SQLite schema migrations (PRAGMA user_version) + data-safety model (#92)

## [2.4.0] - 2026-09-19

### Added
- keep the data folder out of Time Machine & iCloud backups by default (#91)

## [2.3.0] - 2026-09-19

### Added
- recommend at-rest encryption during first-run setup (#90)

## [2.2.0] - 2026-09-19

### Added
- SHA-256 integrity verification for on-device model downloads (#89)

## [2.1.0] - 2026-09-19

### Added
- Google-Docs-style comments margin rail with resolve/reopen (#88)

## [2.0.0] - 2026-09-19

### Changed
- rename project identity SessionNotes → Aletheia (#87) (breaking)

## [1.23.0] - 2026-09-19

### Added
- security overview panel in Settings (#86)

## [1.22.0] - 2026-09-19

### Added
- on-device audit log of ePHI-affecting actions (HIPAA §164.312(b)) (#85)

## [1.21.0] - 2026-09-19

### Added
- add audio-retention privacy setting (transcript-only by default) (#84)

## [1.20.0] - 2026-09-19

### Added
- add idle auto-lock timeout (HIPAA automatic logoff)

## [1.19.0] - 2026-09-19

### Added
- show local AI engine status and active model

## [1.18.0] - 2026-09-19

### Added
- add SQLite-backed persistence core

## [1.17.0] - 2026-09-19

### Added
- add domain-neutral persistence-core seam

## [1.16.0] - 2026-09-19

### Added
- consistent DB snapshots for safe migrations and rollback

## [1.15.0] - 2026-09-19

### Added
- end-to-end-encrypted backup engine (local + staged iCloud)

## [1.14.0] - 2026-09-18

### Added
- note format in Settings (default free text) + Settings in app menu

## [1.13.0] - 2026-09-18

### Added
- inline transcript commenting — select a passage, comment in place

## [1.12.2] - 2026-09-18

### Fixed
- Aletheia menu name, always-visible New Patient, open Background

## [1.12.1] - 2026-09-18

### Fixed
- avoid await inside && autoclosure in ToolHealth
- live-updating status + reliable screen-recording detection

## [1.12.0] - 2026-09-18

### Added
- draft clinical progress notes in SOAP/DAP/BIRP formats

## [1.11.1] - 2026-09-18

### Fixed
- name the release DMG Aletheia-<ver>.dmg, not SessionNotes-

## [1.11.0] - 2026-09-18

### Added
- anchor transcript comments to a time in the session

## [1.10.0] - 2026-09-18

### Added
- multi-thread patient chat with a thread browser

### Fixed
- use a closure for onAppear so the defaulted reloadThreads type-checks

## [1.9.0] - 2026-09-18

### Added
- render assistant chat answers as native Markdown

## [1.8.0] - 2026-09-18

### Added
- optional Keychain unlock — remember the data key on this Mac
- enable/disable Tier-2 encryption from Settings with bulk migration and unlock gate
- encrypt session audio at rest with a streaming chunked cipher
- encrypt transcripts, summaries, chat, patient records and the notes DB at rest
- add FileProtector I/O choke point and EncryptionManager key lifecycle

## [1.7.0] - 2026-09-18

### Added
- add at-rest encryption crypto core (envelope cipher + passphrase keystore)
- tiered Ollama model picker in Settings (lighter / recommended / heavier)
- menu-bar Start/Pause/Stop for session recording

## [1.6.0] - 2026-09-17

### Added
- append-only local receipt for legal acceptance
- require & record local acceptance of Terms and Privacy Policy

## [1.5.0] - 2026-09-17

### Added
- disable Apple Intelligence backend (keep AI provably on-device)

## [1.4.0] - 2026-09-17

### Added
- edit the transcript in-app and warn on runaway recordings

## [1.3.0] - 2026-09-17

### Added
- Touch ID / password app lock and FileVault guidance (Tier 1)
- patient background — clinical history + medications, fed to AI context

### Fixed
- keep session header buttons from overflowing a narrow window

## [1.2.0] - 2026-09-17

### Changed
- The app is now named **Aletheia** everywhere it's shown — the window and menu,
  permission prompts ("Aletheia would like to…"), setup, and the distributed
  `Aletheia.app`/DMG. Internal identifiers (bundle id, Xcode target) are
  unchanged, so existing permission grants and data folders carry over.

## [1.1.0] - 2026-09-17

### Added
- Setup now asks for Calendar and Reminders access up front (optional), so the
  "Schedule Next Session" and "Remind Me" features are ready without an
  interrupting permission prompt mid-task. Declining just leaves those features
  off; you can enable them anytime. Access is checked without prompting.
- Hardware summary now shows the detected chip and CPU core count (e.g.
  "Apple M3 Pro · 12-core CPU · 36 GB memory") instead of a generic label.

## [1.0.0] - 2026-09-17

### Added
- Native macOS app: record a session's microphone and call audio (two tracks,
  via ScreenCaptureKit — no virtual audio driver), on-device Whisper
  transcription, and local-LLM summaries.
- Cross-session chat grounded in the transcripts, with the session date cited
  as its source; full-text search across patients/sessions; Markdown export of a
  session or a whole patient history.
- Therapist annotations: freeform per-session notes and inline transcript
  comments, stored in a local SQLite database inside the data folder and fed
  into the AI chat so it weighs the therapist's own judgment.
- Tiered on-device AI backend, chosen automatically and overridable in Settings:
  Apple Intelligence → built-in llama.cpp (staged) → Ollama. Hardware-aware
  model recommendations and in-app model downloads.
- Apple-platform integration: completion notifications, Siri/Shortcuts
  (App Intents), opt-in metadata-only Spotlight indexing, and "Remind Me" /
  "Schedule Next Session" via Reminders and Calendar.
- Guided first-run setup, permission/status checks, and an in-app updater that
  polls an appcast and installs new versions.

- Streaming chat responses with an adaptive, word-by-word reveal and a Stop
  control, across all backends (Ollama, Apple Intelligence, llama.cpp).
### Fixed
- Screen Recording setup no longer re-prompts on every health check and doesn't
  need an app relaunch: permission is checked with a non-prompting preflight, the
  system dialog appears once from an explicit Allow, and the checklist turns green
  live the moment access is granted.

### Infrastructure
- App Sandbox + Hardened Runtime; no external process is ever spawned.
- GitHub Actions pipeline (first-party/Apple/Homebrew tooling only): CI matrix
  (`macos-15` required, `macos-26` canary), continuous-delivery DMG artifacts,
  and a tag-driven release that generates the updater feed and supports
  secret-gated Developer ID signing + notarization.
- Automated releases from Conventional Commits: merges to `main` derive the
  semver bump, stamp the changelog and app version, tag, and publish — no manual
  version bumping. See the README's Releasing section.

### Not yet shipped
- Embedded llama.cpp needs a one-time Mac bring-up (see the README).
- Google-Docs-style inline comment highlighting is in progress.
