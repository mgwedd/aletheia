# Acceptance criteria

Each check is one line: what you do, then what you see. Every check is proven by a fitness function, `test_<ID>`, which drives the real app in CI against a fixed, repeatable setup. A check counts as accepted only when its test passes in CI. A pending test is not accepted, and neither is a failing one. The run's ledger lists each check as passed, failed or pending and leads with "Accepted: N of M checks".
Exact wording, every option and every edge case live in BEHAVIOR-REFERENCE.md, where each item rolls up to one check here.
Checks marked (dev build) need a Debug or developer build and are skipped on a Release build.

## 1. Fresh install: setup checklist and terms (SETUP)
Before you start: a Release build and a throwaway data folder, with no earlier Aletheia settings on this Mac.
- **SETUP-01** Launch Aletheia for the first time → a **Set up Aletheia** sheet appears that you can't dismiss.
- **SETUP-02** Read the checklist → Terms, data folder, microphone, call audio, speech model and AI rows appear in that order with an "N of M done" counter.
- **SETUP-03** Click the Terms of Use and Privacy Policy links → each opens the copy bundled in Aletheia and reads with Wi-Fi off.
- **SETUP-04** Tick the agree box → **Finish setup** stays disabled until a data folder is chosen.
- **SETUP-05** Open the consent guide link → the guide opens with numbered sections and a sample consent clause.
- **SETUP-06** Click **Choose Folder…** and pick your throwaway folder → the row shows its path and **Finish setup** enables.
- **SETUP-07** Click **Allow Microphone** → the macOS microphone prompt appears; denying it turns the row into a problem with **Open Settings**.
- **SETUP-08** Click **Allow** on Call audio capture and grant it in macOS → the row turns done without a restart.
- **SETUP-09** Look at the speech model and AI rows → each offers a download with its size, then shows ready once installed.
- **SETUP-10** Click **Finish setup**, quit and reopen → the sheet doesn't appear again.
- **SETUP-11** Look for "Protect your data" (dev build) → it recommends encryption with a button that doesn't block **Finish setup**.
- **SETUP-12** Finish setup, then open a build with newer terms → the **Set up Aletheia** sheet returns until the new terms are accepted, and each acceptance is dated on this Mac.

## 2. Add a patient (PATIENT)
Before you start: setup finished, a data folder chosen, and the disk encrypted with FileVault.
- **PATIENT-01** Look at the sidebar with no patients → it shows "No Patients Yet" and an **Add Patient** button.
- **PATIENT-02** Press ⌘N → a **New Patient** sheet opens and **Add** stays disabled while the name is blank.
- **PATIENT-03** Type "Jane Doe" and click **Add** → her page opens showing her name and "No sessions".
- **PATIENT-04** Add "adam lee" and "Joanne Fox" → the sidebar lists patients alphabetically regardless of case, each with initials and an added date.
- **PATIENT-05** Rename Jane with stray spaces and save → the name is saved trimmed, and a blank name shows "A name is required."
- **PATIENT-06** Fill in Clinical history and Patient notes and save → the profile card shows only the filled rows; with both empty it says "Nothing recorded yet."
- **PATIENT-07** Type a change in the editor and click **Cancel** → "Discard your changes?" offers **Discard Changes** and **Keep Editing**.
- **PATIENT-08** Click **Delete patient…** and type her name → **Delete Patient** enables on a match, and her folder and everything in it is gone, and the confirmation first names the copies that can remain: the rolling snapshots in .backups, Time Machine and other backups, and exports.
- **PATIENT-09** Add a patient on a Mac with FileVault off → a "Turn on FileVault" alert appears and no patient is added.
- **PATIENT-10** Choose **Edit Profile…** and click **Add medication** twice (dev build) → two rows with Medication and Dose fields appear; **Remove medication** deletes one; none left reads "None recorded."
- **PATIENT-11** Save medications with one row left blank (dev build) → the blank row is dropped, and the profile card lists the others as name and dose.
- **PATIENT-12** Edit and save a patient in a Release build → no Medications table appears, and medications stored earlier by a dev build are kept.

## 3. Start a session (SESSION)
Before you start: a patient with no sessions.
- **SESSION-01** Open the patient with no sessions → the list says "No Sessions Yet" with a **New session** button.
- **SESSION-02** Click **New session** twice within 10 seconds → only one session is created; a second click after the 10-second debounce makes another, listed newest first with its date and time.
- **SESSION-03** Record, stop and transcribe a session → its row reads "Recording in progress", then "Transcribing…", then shows a Transcript chip; saving a note adds a Note chip.
- **SESSION-04** Click **Review in Settings…** on the set-aside recordings warning strip → Settings opens on its "Set-aside recordings" page.
- **SESSION-05** In a Release build, search the Shortcuts app for Aletheia → it offers no actions.
- **SESSION-06** Schedule a repeating next session with "Save an .ics file" ticked (dev build) → Calendar gains an event with no patient name and the file is saved.
- **SESSION-07** Choose **Remind Me** > Tomorrow (dev build) → Reminders gains a "Follow up" item that names no patient.
- **SESSION-08** Run the Shortcuts action "Show Today's Sessions" (dev build) → sessions are listed by initials, and when locked it refuses.
- **SESSION-09** With FileVault off, click **New session** → an alert asks you to turn on FileVault and no session is created.

## 4. Record a session (RECORD)
Before you start: a session with no transcript, a Mac that can play some audio, and microphone and call-audio permissions not yet decided.
- **RECORD-01** Click **Record Session** and allow the microphone → recording starts with a red dot, a running timer, **Pause** and **Stop Recording**.
- **RECORD-02** Play audio on this Mac → the "Your microphone" and "Call audio" level bars move with the sound.
- **RECORD-03** Open another session, of any patient, while recording → it shows "Recording another session" and offers no **Record Session**.
- **RECORD-04** Click **Pause** → the timer holds, the chip says **Paused**, and **Resume** continues the same session.
- **RECORD-05** Record about 90 seconds with no call audio → the pane warns that only your microphone is being recorded.
- **RECORD-06** Deny microphone access and click **Record Session** → no recording starts and an alert says how to allow it in System Settings.
- **RECORD-07** Click **Record Session** on a Mac with FileVault off → recording doesn't start and a "Turn on FileVault" alert appears.
- **RECORD-08** Let a recording run past 90 minutes → a "Still recording" alert asks whether you forgot, with **Keep Recording** and **Stop Now**.
- **RECORD-09** Click **Stop Recording** → the microphone and call audio are saved as two files with the session, no audio is left anywhere else, and transcription starts by itself.
- **RECORD-10** Force-quit Aletheia mid-recording and reopen → the audio up to that moment is recovered into its session.
- **RECORD-11** Force-quit mid-recording, delete that patient's folder in Finder and reopen → a warning strip says a recording is set aside, naming no patient.
- **RECORD-12** Click **Review in Settings…** and recover the item into a session → its audio is added to that session and leaves the list.
- **RECORD-13** Click **Delete…** on a set-aside recording and confirm → the audio is gone for good.
- **RECORD-14** Click **Pause**, speak, then **Resume** and **Stop Recording** → nothing said while paused is in the saved audio.
- **RECORD-15** Click **Import Audio…** and pick an audio file → it becomes the session's recording, the original file is untouched, and transcription starts by itself.
- **RECORD-16** Click **Import Audio…** for a patient who hasn't agreed to recording yet → the consent sheet appears first, and the file picker opens only after you confirm.
- **RECORD-17** Pick a file that isn't audio → a "Something went wrong" alert says it couldn't be read as audio and nothing is saved.
- **RECORD-18** Open a session that already has a recording → it offers neither **Record Session** nor **Import Audio…**, and an import into it is refused, leaving the recording as it was.
- **RECORD-19** Import audio into a session whose note is signed → it is refused with an alert and nothing is saved.
- **RECORD-20** Click **Import Audio…** on a Mac with FileVault off → no picker opens and a "Turn on FileVault" alert appears.
- **RECORD-21** Click **Import Audio…** without a license key → an alert says a license key is needed, no picker opens and nothing is saved.
- **RECORD-22** Click **Import Audio…** and pick two files, a microphone track and a call track (such as the two `.caf` files Aletheia exports) → the one named "call" becomes the call audio, the other the microphone, and neither original is touched.
- **RECORD-23** Pick three or more files in **Import Audio…** → an alert asks for one file or two, and nothing is saved.


## 5. Transcribe (TRANSCRIBE)
Before you start: a session that has a recording and no transcript.
- **TRANSCRIBE-01** Click **Transcribe** before downloading the speech model → you're told to download it first in Settings.
- **TRANSCRIBE-02** Download the model and click **Transcribe** → a progress band shows the stage and a percentage that never goes backwards.
- **TRANSCRIBE-03** Click **Transcribe** on a second session while the first runs → it shows "Waiting to transcribe" with **Cancel** and starts when the first finishes.
- **TRANSCRIBE-04** Leave the session mid-transcription → it keeps running and the menu bar shows its progress.
- **TRANSCRIBE-05** Click **Cancel** during a transcription → no transcript is written, any partial transcript is discarded, the recording is kept, and the session shows a warning icon until it is transcribed or deleted.
- **TRANSCRIBE-06** Quit mid-transcription and reopen → that session is transcribed again.
- **TRANSCRIBE-07** Open the finished transcript → lines carry [MM:SS] time stamps, with "You" for your microphone and the patient's first name for the call.
- **TRANSCRIBE-08** Check the recording after a successful transcription → it is deleted and the row no longer shows "Audio".
- **TRANSCRIBE-09** Transcribe a silent recording → the tab says no speech was detected and the recording is kept.
- **TRANSCRIBE-10** Type in the transcript → an edit bar appears with **Save** and **Discard**, and ⌘S keeps the edit.
- **TRANSCRIBE-11** Edit the transcript, then click another session → "Save your transcript edits?" offers **Save**, **Discard Edits** and **Cancel**.
- **TRANSCRIBE-12** Turn on "Keep raw audio after transcription" with encryption on (dev build) → the recording is kept after the transcript is saved.
- **TRANSCRIBE-13** Damage the downloaded speech model, then click **Transcribe** → a "Something went wrong" alert gives the reason and a "Transcription needs attention" notification arrives.
- **TRANSCRIBE-14** Transcription fails partway (the audio can't be read) → no transcript is written, the recording is kept, and a "Transcription needs attention" notification arrives.
- **TRANSCRIBE-15** Transcribe with encryption on → the transcript is saved, and its text can't be read from the data folder without the passphrase.
- **TRANSCRIBE-16** Turn on "Keep raw audio after transcription" with encryption off → the recording is still deleted once the transcript is saved, so audio is never left readable on disk.
- **TRANSCRIBE-17** Re-transcribe a silent recording that already has a transcript → the earlier transcript and the recording are kept, and the tab says no speech was detected.
- **TRANSCRIBE-18** Transcribe a recording for the first time with raw audio not kept → a one-time notice says the recording was deleted after transcription, and it is not shown again.

## 6. Comment on the transcript (COMMENT)
Before you start: a session with a saved transcript and no comments.
- **COMMENT-01** Select a few words in the transcript → a floating **Comment** button appears just above the selection.
- **COMMENT-02** Press ⌥⌘M → a composer opens showing the quote, and **Save comment** is disabled while the text is blank.
- **COMMENT-03** Type a comment and press ⌘Return → a card appears in the side rail and the passage is highlighted.
- **COMMENT-04** Click the highlighted passage → its card is focused and scrolled into view.
- **COMMENT-05** Drag the divider between transcript and comments → the split is remembered, and dragging far enough folds a side away.
- **COMMENT-06** Edit a card, then click **Resolve** → it moves into a collapsed "Resolved (N)" section, and **Reopen** brings it back.
- **COMMENT-07** Click **Delete** on a card → it disappears at once with no confirmation.
- **COMMENT-08** Delete a patient → her comments are gone and no longer listed for any session.

## 7. Draft and edit progress notes (NOTE)
Before you start: a session with a transcript, the AI model downloaded, and a comment and patient background containing a distinctive fact.
- **NOTE-01** Open the **Notes** tab → a picker offers Summary, SOAP, DAP, BIRP, GIRP and **My Notes**.
- **NOTE-02** Pick SOAP with no SOAP note yet → the pane says "No SOAP note yet" and offers **Generate SOAP note**.
- **NOTE-03** Click **Generate SOAP note** → text streams in under a status line with elapsed time, and **Stop** appears.
- **NOTE-04** Read the finished SOAP note → it has Subjective, Objective, Assessment and Plan, with speakers as "You" and the client's first name.
- **NOTE-05** Click **Stop** while text is streaming → the text written so far is kept.
- **NOTE-06** Open the **Length** menu → Concise, Natural and Detailed appear with an AI effort choice.
- **NOTE-07** Choose **Edit SOAP Prompt…** → a sheet lets you save your own instructions, and **Reset to Default** restores them.
- **NOTE-08** Request a note while a chat answer is running → a waiting status with **Cancel** appears, and the note starts when the answer ends.
- **NOTE-09** Move the AI model out of its folder and click **Generate** → an alert says it isn't downloaded and offers **Download Model**.
- **NOTE-10** Click **Regenerate** on a hand-edited note → "Replace your edited note?" asks before replacing it.
- **NOTE-11** Click **Edit** and use ⌘B and ⌘I → text shows formatted with no raw Markdown symbols, and **Save** keeps it.
- **NOTE-12** Change the transcript after generating a note → the note shows an "Outdated" message with **Regenerate**.
- **NOTE-13** Type in **My Notes** → it saves as you type and the AI never rewrites it.
- **NOTE-14** Generate a note on a transcript too long to read at once → the status steps through "Processing transcript" and the note ends with a coverage line.
- **NOTE-15** Click **Copy** on a note and paste into a rich-text app → headings and lists come through formatted, and the button shows "Copied".
- **NOTE-16** Put a line in a transcript telling the AI to ignore instructions, then generate a note → the note summarises normally and ignores it.

## 8. Chat and Q&A (CHAT)
Before you start: a patient with at least two sessions that have transcripts, and the AI model downloaded.
- **CHAT-01** Open a session's **Ask** tab → it shows "Ask a question about this session" and a question box.
- **CHAT-02** Type a question and press Return → it appears as a bubble and the answer streams in with a **Stop** button.
- **CHAT-03** Let the answer finish → a "Read:" line says what part of the session was read.
- **CHAT-04** Click **Stop** mid-answer → the part already shown stays in the conversation.
- **CHAT-05** Ask while a note is generating → a waiting status with **Cancel** appears, and cancelling removes the unanswered question.
- **CHAT-06** Quit and reopen, then open the **Ask** tab → the earlier questions and answers are still there.
- **CHAT-07** Hold the microphone button in the **Ask** box and speak → your words appear in the draft as you talk.
- **CHAT-08** Click **Ask about this patient** → an "Ask about Jane Doe" window opens with an empty chat.
- **CHAT-09** Click **New Chat** a few times and ask different questions → a **Chats** list shows threads newest first, and they survive a relaunch.
- **CHAT-10** Delete the patient while their chat window is open → it says "This patient is no longer available."
- **CHAT-11** Ask "How has sleep changed across sessions?" → the answer cites sessions by date and ends with a "Sources:" line.
- **CHAT-12** Read the "Read:" line under a patient answer → it says how many sessions' notes and transcripts were read, and at what effort.
- **CHAT-13** Click **Compact** on a long chat → a "Conversation compacted" card replaces the older messages.
- **CHAT-14** Ask for a flowchart of the main themes → a diagram appears with a **Diagram**/**Source** toggle.
- **CHAT-15** Ask for a code block and click its **Copy** button → it shows "Copied".
- **CHAT-16** Remove the AI model and ask a question → a "Something went wrong" or engine alert appears, the question stays in the chat, and **Retry** asks it again.
- **CHAT-17** Right-click a thread in the **Chats** list → the menu offers Rename and Delete.
- **CHAT-18** Set a different effort in an **Ask** tab, the patient chat and notes → each keeps its own setting when you switch back.

## 9. Summaries prepared in the background (DIGEST)
Before you start: a patient whose sessions have transcripts too long for this Mac to read at once, and the AI model downloaded.
- **DIGEST-01** Open the patient page → a row shows "Summaries: N of M ready", later "all N ready".
- **DIGEST-02** Open a long session's **Transcript** tab while a summary builds → it shows "Processing transcript" with a step bar.
- **DIGEST-03** Click **Pause** on the summaries row, then record and stop a session → the row says why it is paused and stays paused, and an info alert says transcription is paused with work pending.
- **DIGEST-04** Edit a long transcript and save → its summary is rebuilt.
- **DIGEST-05** Remove the AI model mid-build → the tab shows "Couldn't build the digest" with **Retry**.

## 10. Search and Spotlight (SEARCH)
Before you start: two patients with transcripts, notes and comments, one of them named like "Joanne Fox".
- **SEARCH-01** Press ⌘F while the cursor is in a transcript → the sidebar search field takes focus.
- **SEARCH-02** Type a word from a transcript into the sidebar field → results cover the detail pane.
- **SEARCH-03** Look at the results → they are grouped Patients, Sessions, Psychotherapy notes, Progress notes, Comments and Transcripts, with highlighted snippets.
- **SEARCH-04** Search a word that appears in many places → each group shows its best five and a "Show more" row.
- **SEARCH-05** Press ↓ then Return on a result → it opens and the search clears; Esc clears a query.
- **SEARCH-06** Open a transcript result → that session opens on the Transcript tab, scrolled to the matching line.
- **SEARCH-07** Search the partial word "thera" → sessions mentioning "therapy" appear, best match first.
- **SEARCH-08** Search for text that appears nowhere → the results say "No results" for that query.
- **SEARCH-09** Transcribe a session and search right away → a line says results may be incomplete, then fills in by itself.
- **SEARCH-10** Quit, delete search.sqlite from the data folder and reopen → search still works and nothing is lost.
- **SEARCH-11** Lock the app and search for a word from a transcript → nothing is found, not even by scanning files, and after you unlock, search works again.
- **SEARCH-12** Turn on "Find patients in Spotlight" (dev build) → Spotlight lists patients by initials, never names.
- **SEARCH-13** Search a transcript word in capitals, then in lowercase → both return the same results, and accents are ignored.
- **SEARCH-14** Type "Joanne" plus a topic word from her notes → only her sessions mentioning the topic appear, and adding a date word narrows them to that date.
- **SEARCH-15** Delete a patient, then search a word from her transcript → no result mentions her.

## 11. Export and archive (EXPORT)
Before you start: two patients with transcripts, notes and comments, one session with a kept recording, and one with nothing in it.
- **EXPORT-01** Click **Export All Records…** in Settings > Backups and pick a folder → a dated folder appears with one folder per patient.
- **EXPORT-02** Click **Cancel** during an export → the toast goes away and nothing is left in the destination.
- **EXPORT-03** Let an export finish → a toast reads "Export ready" with counts and **Show in Finder**.
- **EXPORT-04** Export to a destination that can't be written to → a toast reads "Export didn't finish".
- **EXPORT-05** Export All Records to an iCloud Drive or other synced folder → the export is refused and nothing is written to the folder.
- **EXPORT-06** Open the export folder → "Read me.txt" gives the counts, and each patient has a folder with one dated folder per session.
- **EXPORT-07** Open a session's folder → it holds the transcript, one text file per note and recordings that play normally, but no comments or psychotherapy notes.
- **EXPORT-08** Export a patient whose name has slashes or colons → illegal characters in the folder name become "-".
- **EXPORT-09** Click **Export all records** on a patient's page → a single zip of text files appears, one folder per session.
- **EXPORT-10** Click **Export** on a note and choose PDF, Word or Markdown → a save panel suggests a name and the file opens correctly.
- **EXPORT-11** Export a whole session from its header → the file holds the patient's name, date, Summary and Transcript.
- **EXPORT-12** Pick a folder on a disk that isn't encrypted → a "This disk isn't encrypted" warning appears and nothing has been written to the folder.

## 12. Lock and privacy shield (LOCK)
Before you start: a Mac that can authenticate with Touch ID or a password.
- **LOCK-01** Quit and reopen Aletheia with App lock on → a lock screen covers the window until you unlock.
- **LOCK-02** Lock the Mac screen and return → Aletheia is locked.
- **LOCK-03** Set **Auto-lock after** to 1 minute in **Privacy & Security** and leave Aletheia alone → it locks after about a minute.
- **LOCK-04** Lock the app with a sheet, a popover and the menu bar panel open → everything showing patient content is covered.
- **LOCK-05** Take a screenshot or share your screen → Aletheia's windows are blank to the other app.
- **LOCK-06** Lock the app while a recording runs → the recording keeps going.
- **LOCK-07** Copy a patient's text and paste it elsewhere → it pastes, but clipboard history doesn't keep it.
- **LOCK-08** Select transcript text and open the right-click menu → macOS Writing Tools isn't offered.
- **LOCK-09** With the encrypted folder's key kept on this Mac and App lock saved as off, quit and reopen → the lock screen still covers the window.
- **LOCK-10** In that state, open **Settings** > **Security** → App lock shows on and can't be changed.
- **LOCK-11** With the key not kept on this Mac, turn App lock off → it asks for Touch ID or your password first, and the app stops locking at launch.
- **LOCK-12** Quit and reopen with the key kept, then unlock with Touch ID → patients appear with no passphrase asked, and none showed before.
- **LOCK-13** On a fresh install, open **Settings** > **Security** → "Lock when Aletheia is hidden" is on; an install that turned it off keeps it off.
- **LOCK-14** Delete a session's recording whose temporary audio folder can't be removed → the app says the recording wasn't deleted.

## 13. Encryption at rest (ENCRYPT)
Before you start: a developer build, or a data folder that is already encrypted; Privacy & Security shows the encryption controls only then.
- **ENCRYPT-01** In a Release build with an unencrypted folder, look for encryption controls → none are offered.
- **ENCRYPT-02** Type a passphrase under 12 characters in **Turn On…** (dev build) → **Continue** stays disabled, and under 8 characters the strength meter reads "Weak".
- **ENCRYPT-03** Reach the recovery key step (dev build) → 24 words show, with **Copy Words**, **Save as PDF…** and **Print…**.
- **ENCRYPT-04** Reach the last step (dev build) → **Encrypt my data** stays unavailable until both acknowledgement boxes are ticked.
- **ENCRYPT-05** Open data folder files in Terminal after encrypting (dev build) → transcripts, notes and recordings are unreadable while folder names stay readable.
- **ENCRYPT-06** Turn off "Unlock automatically on this Mac", then reopen (dev build) → a screen asks for the passphrase before any patient shows.
- **ENCRYPT-07** Enter a wrong passphrase (dev build) → an error says it didn't unlock the data, and repeated failures add a wait.
- **ENCRYPT-08** Click **Change Passphrase…** (dev build) → it asks for the current and a new passphrase, and the recovery key keeps working.
- **ENCRYPT-09** Click **Turn Off…** and confirm (dev build) → files are decrypted before the key is removed.
- **ENCRYPT-10** Stop a recording while the encrypted data folder is locked (dev build) → the audio stays out of the session folder, transcription doesn't start, and reopening adds it.

## 14. Backups, data folder and upgrades (BACKUP)
Before you start: some patients and sessions in the data folder, and a copy of it to experiment on.
- **BACKUP-01** Open **Settings** > **Backups** → a banner says the data folder is kept out of Time Machine and iCloud backups, that Back Up Now is not available in a released build, and that arranging a backup is up to you.
- **BACKUP-02** Turn off the option to keep your data out of backups, then on again → while it is off, the banner says Time Machine includes the folder and to use an encrypted disk; once on, it says the folder is left out of Time Machine and iCloud backups.
- **BACKUP-03** Click **Show backups folder in Finder** → the hidden backups folder opens.
- **BACKUP-04** Delete a patient and open the backups folder → a database snapshot taken just before is there.
- **BACKUP-05** Open a data folder written by an older version → it opens and upgrades in place with patients and sessions intact.
- **BACKUP-06** Open a data folder written by a newer version → an "Update Aletheia" alert appears and the files are left untouched.
- **BACKUP-07** Corrupt one patient.json in a data folder copy and open it → the sidebar says one record couldn't be read, everything else opens and the damaged file is unchanged.
- **BACKUP-08** In a dev build with encryption on, click **Back up now** and pick another folder → an archive is written there and no session text is readable in it.
- **BACKUP-09** Restore a backup archive on this Mac → it unlocks with Touch ID or your passphrase; on a new Mac, your recovery key unlocks it.

## 15. Settings (SETTINGS)
Before you start: setup finished.
- **SETTINGS-01** Press ⌘, in a Release build → Settings opens with General, AI and models, Formats, Backups, Privacy & Security, License key and Licenses & Legal panes.
- **SETTINGS-02** Look at the data folder in **General** → its path shows with **Choose…**, and the same folder is in use after relaunch.
- **SETTINGS-03** Pick Light, then Dark under Appearance → the whole app changes at once and stays that way after relaunch.
- **SETTINGS-04** Look at the defaults on a fresh install → automatic transcription is on, keeping data out of backups is on, raw audio kept is off, and notification names are off.
- **SETTINGS-05** Open **AI and models** > **Speech recognition** and download a model → a percent bar fills and the row shows Installed.
- **SETTINGS-06** Look at the **Language model** card → there is no engine menu, since the built-in model is the only engine, and Apple Intelligence is off.
- **SETTINGS-07** Pick a built-in model → its license link shows before anything downloads.
- **SETTINGS-08** Start the model download → progress reads "Downloading model…" then "Verifying downloaded model…".
- **SETTINGS-09** Add and remove a risk phrase → the list updates, and **Reset to Defaults** asks first.
- **SETTINGS-10** Open **Formats** → you can set the default format and summary length and toggle what drafts include.
- **SETTINGS-11** Turn on "Show recording diagnostics" and record → the recording pane gains a call-audio diagnostics readout.
- **SETTINGS-12** Open **Licenses & Legal** → the Terms of Use and Privacy Policy links, **Consent Guide…** and third-party notices are there.
- **SETTINGS-13** Choose an iCloud Drive or cloud-synced folder as the data folder → it is refused, asking for a folder that stays on this Mac; the current folder is kept.
- **SETTINGS-14** Open Aletheia with its data folder now synced → a **Move data to this Mac** sheet offers to copy and verify it, then keep or delete the old one.

## 16. Security panel, activity log and Doctor (SECURITY)
Before you start: a data folder with some activity (unlock, export, delete a patient).
- **SECURITY-01** Open **Settings** > **Privacy & Security** → a posture card lists App lock, FileVault, the audit log and network under a headline.
- **SECURITY-02** Open the **Network access** card → it reads "Aletheia can't connect to the internet" in a shipped build.
- **SECURITY-03** Click **Copy** under "Verify it yourself" → the button reads "Copied" and the clipboard holds the codesign command.
- **SECURITY-04** Open the activity log after unlocking, exporting and deleting a patient → each adds a dated entry with no patient names.
- **SECURITY-05** Click **Verify integrity & export audit report** → "Integrity verified" appears and a report is saved.
- **SECURITY-06** Change an activity log entry outside Aletheia, then click **Verify integrity & export audit report** → "Integrity check failed" appears with the entry number.
- **SECURITY-07** Choose **Help** > **Aletheia Doctor…** → checks are grouped and each shows OK, Warning or Problem.
- **SECURITY-08** Click **Copy report** in Doctor → the button reads "Copied" and the report holds no patient names.

## 17. Software updates (UPDATE)
Before you start: a Release build of Aletheia and an internet connection; to see an offer, an older build or a newer release.
- **UPDATE-01** Open **Settings** > **General** > **Software update** → it shows the version and the automatic-check switch.
- **UPDATE-02** Click **Check for updates** when up to date → Settings says you are up to date, and no alert or banner appears.
- **UPDATE-03** Turn off Wi-Fi and click **Check for updates** → Settings says it couldn't check, and no alert appears.
- **UPDATE-04** Run an older build against a newer release → a banner above the main window reads "Aletheia X is available." with **What's New…**, **Remind me later** and **Download update**, without blocking the app; **What's New…** opens a prompt offering **View downloads**, **Skip this version**, **Remind me later** and **Download update**.
- **UPDATE-05** Click **Remind me later** → the banner (and prompt) closes and the same version is offered at a later check.
- **UPDATE-06** Click **Skip this version** → automatic checks don't offer it again.
- **UPDATE-07** Click **Download update** → the disk image downloads, is verified and opens, and Aletheia stays open.
- **UPDATE-08** Click **Download update** for a release with a mismatched checksum → the file is deleted, nothing is opened, and the generic releases page opens instead.
- **UPDATE-09** Switch away from and back to Aletheia repeatedly → at most one automatic check runs every 30 minutes.
- **UPDATE-10** Click **Download update** for a release that lists no checksum → nothing is downloaded and the downloads page opens instead.

## 18. Notifications (NOTIFY)
Before you start: allow Aletheia notifications in System Settings, and put Aletheia in the background.
- **NOTIFY-01** Start a transcription for the first time → macOS asks for notification permission.
- **NOTIFY-02** Let a transcription finish → a "Transcript ready" notification appears that shows no patient name or initials.
- **NOTIFY-03** Transcribe a silent recording → a "Transcription needs attention" notification appears.
- **NOTIFY-04** Finish generating a note → a "Summary ready" notification appears.
- **NOTIFY-05** Finish an export → an "Export ready" notification appears that shows no patient name or initials.
- **NOTIFY-06** Turn on "Show patient names in notifications" and transcribe → the notification names the patient in full.
- **NOTIFY-07** With "Show patient names in notifications" off, finish a transcript, a transcription problem, a note and an export → none of the four notifications shows a name or initials.
- **NOTIFY-08** Turn on "Show patient names in notifications", lock the app and let a transcription finish → the notification shows no patient name or initials.

## 19. Menu bar item, menus and shortcuts (MENUBAR)
Before you start: at least one patient and the app unlocked.
- **MENUBAR-01** Look at the menu bar icon → a waveform when idle, a record symbol while recording, a pause symbol while paused.
- **MENUBAR-02** Click the icon while idle → it shows "Not recording", a **Patient** picker and **Start recording**.
- **MENUBAR-03** Choose a patient and click **Start recording** → a new session is created, recording begins and the main window comes forward.
- **MENUBAR-04** Look at the panel while recording → it shows a **Recording** chip, the patient's initials (for example J.D.), a timer, level bars, **Pause** and **Stop and save**.
- **MENUBAR-05** Click **Pause** in the panel → a **Paused** chip and **Resume** appear.
- **MENUBAR-06** Click **Stop and save** → the recording is saved and the panel returns to "Not recording".
- **MENUBAR-07** Delete every patient and open the panel → it asks you to add a patient in the main window first.
- **MENUBAR-08** Make **Start recording** fail, such as with FileVault off → the reason appears under the button and the panel stays open.
- **MENUBAR-09** Lock the app and open the panel → it shows "Aletheia is locked" with **Unlock**, and no patient name or recording detail.
- **MENUBAR-10** Press ⌘/ → a Keyboard Shortcuts window lists three groups.
- **MENUBAR-11** Press ⌘N, ⌘G and Esc in their places → a patient is added, a note is generated and a sheet closes.
- **MENUBAR-12** Choose **Help** > **Report a Bug…** → your browser opens the feedback page, with no patient information in the address.
- **MENUBAR-13** Rest the pointer for two seconds on a control with a help tip → a "how this works" popover appears once.
- **MENUBAR-14** Quit with work running → no alert appears and interrupted work is saved for the next launch.
- **MENUBAR-15** While a recording is running, open the panel and try to start another → no second recording starts and the first keeps recording.

## 20. Build and privacy checks from Terminal (BUILD)
Before you start: the Release app at /Applications/Aletheia.app and the repository checked out.
- **BUILD-01** Run `codesign -d --entitlements - /Applications/Aletheia.app` → only the app sandbox, microphone input and user-selected file access are listed; there is no network client.
- **BUILD-02** Run `codesign -d --entitlements - /Applications/Aletheia.app/Contents/XPCServices/NetworkHelper.xpc` → only the sandbox and outgoing network access are listed.
- **BUILD-03** Run `plutil -p /Applications/Aletheia.app/Contents/Info.plist` → microphone and speech purpose strings exist, there are none for Calendar or Reminders, and the version matches Settings.
- **BUILD-04** Run `strings /Applications/Aletheia.app/Contents/MacOS/Aletheia | grep -c -e '--harness-'` → 0, so the Release build has no recording or evaluation harness.
- **BUILD-05** Run `ls -R /Applications/Aletheia.app/Contents` → only speech and language runtimes and the voice-activity detector are bundled, with no analytics SDK and no model files.
- **BUILD-06** In a Release build, check Help, Settings and Shortcuts → Doctor and the built-in model are present; encryption setup, Spotlight, Calendar scheduling and Siri actions are not.
- **BUILD-07** Run `nettop -m tcp -P` while you record, transcribe, draft, ask and search → the Aletheia process makes no connection at all.
- **BUILD-08** Run `nettop` while you check for updates and download a model → only the network helper connects, to github.com, huggingface.co or related hosts.
- **BUILD-09** Run `shasum -a 256` on a downloaded model, then cut a copy short with `truncate` → the good file matches its pinned checksum and the damaged one is refused.
- **BUILD-10** Run `ls -la` on the data folder → patient folders are named by UUID, session folders by date, and only audio and text files are stored.
- **BUILD-11** Start a recording and run `ls -la` on the session folder → no audio is there until you click **Stop Recording**.
- **BUILD-12** Run `cat legal-acceptance.log` in the data folder after accepting terms → one line holds the accepted version, a UTC time and the app version.
- **BUILD-13** Run `bash scripts/scan-secrets.sh` and `bash scripts/check-entitlements.sh` in the repository → both pass.
- **BUILD-14** Search the app's source for network calls such as `URLSession` → none outside the network helper.

## 21. Recording consent (CONSENT)
Before you start: setup finished, FileVault on, and patients "Jane Doe" and "Adam Lee", each with a session that has no recording yet.
- **CONSENT-01** Click **Record Session** for Jane → a **Record consent** sheet asks who consented, how (**Verbal** or **Written**) and when, and **Start recording** stays disabled until you tick the confirmation that everyone in the session consented.
- **CONSENT-02** Choose **Patient** and **Verbal**, tick the confirmation and click **Start recording** → recording starts and the session shows "Consent: verbal, from the patient" with the date and time.
- **CONSENT-03** Start a second session for Jane with the default **First session** policy → recording starts with no sheet and the session shows consent on file since the first date.
- **CONSENT-04** Set **Recording consent** to **Every session** in Settings > General → every new session of every patient asks again before it records.
- **CONSENT-05** Click **Import Audio…** for a session that needs consent → the same sheet appears with **Choose Audio File…**, and no file picker opens until consent is recorded.
- **CONSENT-06** Choose a patient who needs consent in the menu bar panel → the panel asks who and how in place, and **Start recording** stays disabled until you tick the confirmation.
- **CONSENT-07** Set **Recording consent** to **Every session** in Jane's profile editor and save → only Jane is asked every session, and Adam still follows the Settings default.
- **CONSENT-08** Click **Apply to Patients…** in Settings, select several patients or **Select All**, and apply a policy → each selected profile shows that policy, and **Use default** clears it.
- **CONSENT-09** Record consent, then open the activity log → a "Recording consent attested" entry gives the session, the patient's record ID and the method, and no name.
- **CONSENT-10** Export the session as PDF, Word or Markdown, and export all records → each includes a "Recording consent" section with who, how and when.
- **CONSENT-11** Sign the session's note → the session's consent can no longer be changed, and saving a new one is refused.
- **CONSENT-12** Record consent with encryption on (dev build), then quit and reopen → the session folder holds a sealed consent.json that reads back unchanged.

## 22. License key (LICENSE)
Before you start: setup finished.
- **LICENSE-01** Click **Get a Key…** in Settings > License key → your browser opens the Astrea Labs beta application page, and the caption beside it says nothing from this Mac is sent.
