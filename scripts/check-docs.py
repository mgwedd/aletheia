#!/usr/bin/env python3
"""Public documents must not claim anything the app does not do.

Reads README.md, the policy files, docs/*.md and the few source files the
documents quote, and fails if a document drifts from the shipped behaviour.
The rules are few and structural so ordinary rewording does not trip them.
Runs on every pull request in a cheap Ubuntu step (docs-only changes skip the
macOS build, so these must not live in the Swift test target).

Values the documents depend on are read from the Swift source, not copied:
Legal.currentVersion, BackupExclusion.settingTitle and the at-rest encryption
tier. The Swift tests still pin the constants the documents quote
(PassphraseStrength.requiredLength, IdleAutoLockTimeout.defaultTimeout).

Usage: scripts/check-docs.py [--self-test] [ROOT]
"""
import re
import shutil
import sys
import tempfile
from pathlib import Path

failures: list[str] = []


def check(ok: bool, message: str) -> None:
    if not ok:
        failures.append(message)


def swift_constant(root: Path, path: str, pattern: str) -> str:
    match = re.search(pattern, (root / path).read_text(encoding="utf-8"))
    if not match:
        raise SystemExit(f"check-docs: cannot find {pattern!r} in {path}")
    return match.group(1)


def run(root: Path) -> list[str]:
    failures.clear()

    def doc(path: str) -> str:
        return (root / path).read_text(encoding="utf-8")

    def ci(text: str, needle: str) -> bool:
        return needle.lower() in text.lower()

    current_version = swift_constant(
        root, "Sources/App/Services/Legal.swift", r'static let currentVersion = "([^"]+)"')
    setting_title = swift_constant(
        root, "Sources/App/Services/BackupExclusion.swift", r'static let settingTitle = "([^"]+)"')
    tier = swift_constant(
        root, "Sources/App/Services/Crypto/AtRestEncryptionFeatureModule.swift",
        r"let tier: BuildTier = \.(\w+)")
    check(tier in ("production", "preview", "dev"), f"unknown at-rest encryption tier .{tier}")

    def without_setting_title(text: str) -> str:
        # The docs quote the Settings switch that keeps the data folder out of
        # iCloud and Time Machine backups; that title is not an offer of an iCloud backup.
        return " ".join(text.split()).replace(setting_title, "")

    docs_md = sorted(f"docs/{p.name}" for p in (root / "docs").glob("*.md"))
    public = ["README.md", "PRIVACY.md", "SECURITY.md", "TERMS.md", "CONSENT.md"] + docs_md
    terms, privacy, security = doc("TERMS.md"), doc("PRIVACY.md"), doc("SECURITY.md")

    # ---- Every public document ------------------------------------------------
    negation = re.compile(r"(?i)\b(no|not|never|without|nor|none|neither|n't)\b")
    absolute_encryption = re.compile(r"(?i)encrypted at rest|always encrypted|encrypted by default")
    qualified_encryption = re.compile(r"(?i)developer|dev tier|dev-tier|opt-in|if you turn on|production builds do not")
    for path in public:
        text = doc(path)
        check(not ci(text, "ollama"), f"{path} mentions Ollama, which was removed")
        check("11434" not in text, f"{path} mentions port 11434")
        check(not ci(without_setting_title(text), "icloud backup"), f"{path} offers an iCloud backup")
        for p in text.split("\n\n"):
            if ci(p, "ai server"):
                check(bool(negation.search(p)), f"{path} mentions an AI server without saying there is none")
            if re.search(r"(?i)telemetry|analytics", p):
                check(bool(negation.search(p)), f"{path} mentions telemetry/analytics without a negation: {p[:80]!r}")
            # While at-rest encryption is not in the Release tier, no document may
            # present it as something every install has.
            if tier != "production" and absolute_encryption.search(p):
                check(bool(qualified_encryption.search(p)),
                      f"{path} claims encryption at rest but it is not in the Release tier: {p[:80]!r}")

    # ---- Support without patient data -----------------------------------------
    for needle in ["## Support without patient data", "Astrea Labs", "support@astrealabs.com"]:
        check(needle in security, f"SECURITY.md lacks {needle!r}")
    for needle in ["never asks for patient data", "redacts"]:
        check(ci(security, needle), f"SECURITY.md lacks {needle!r}")

    # ---- License key and revocation list --------------------------------------
    for phrase in ["License key", "do not share, transfer, or publish", "revoke", "Pre-release versions",
                   "open, read, search, export, and\ndelete", "14-day grace period",
                   "a revoked key has no grace period", "never require a license key, with no time limit"]:
        check(phrase in terms, f"TERMS.md lacks {phrase!r}")
    # Revocation is not instant: it waits for the next daily list.
    check("when the\nApp next receives the list" in terms or "when the App next receives the list" in terms,
          "TERMS.md must say revocation applies when the App next receives the list")
    check("end your use of the App" not in terms, "TERMS.md contains 'end your use of the App'")
    for phrase in ["License revocation list", "`astrealabs.com`", "contains no license key or other identifier"]:
        check(phrase in privacy, f"PRIVACY.md lacks {phrase!r}")
    # The license backend exists, so the policy must not deny having one.
    for phrase in ["developer backend", "developer\nbackend", "cannot see who uses"]:
        check(phrase not in privacy, f"PRIVACY.md contains {phrase!r}")

    # ---- The acceptance version moves with the policies' dates ----------------
    for path in ["TERMS.md", "PRIVACY.md"]:
        match = re.search(r"_Last updated: (\d{4}-\d{2}-\d{2})_", doc(path))
        if not match:
            check(False, f"{path} has no '_Last updated: YYYY-MM-DD_' line")
        else:
            check(current_version >= match.group(1),
                  f"Legal.currentVersion {current_version} is older than {path}'s date {match.group(1)}")

    # ---- Backups are local only -----------------------------------------------
    for path in ["PRIVACY.md", "docs/HIPAA-SAFEGUARDS.md"]:
        check(not ci(without_setting_title(doc(path)), "end-to-end encrypted backup to your own iCloud"),
              f"{path} describes an iCloud backup")
    for path in ["PRIVACY.md", "SECURITY.md", "docs/ENCRYPTION.md", "docs/HIPAA-SAFEGUARDS.md"]:
        text = without_setting_title(doc(path))
        check(not ci(text, "iCloud backup"), f"{path} mentions an iCloud backup")
        check("Extra Encryption" not in text, f"{path} mentions 'Extra Encryption'")
        check(not ci(text, "re-locks when it's hidden"), f"{path} says the app re-locks when hidden")
        check("Backup also offers" not in text, f"{path} contains 'Backup also offers'")
    for path in ["PRIVACY.md", "TERMS.md", "SECURITY.md", "README.md", "docs/ENCRYPTION.md",
                 "docs/HIPAA-SAFEGUARDS.md", "docs/DESIGN-DECISIONS.md"]:
        check(not ci(doc(path), "ollama") and "11434" not in doc(path), f"{path} mentions Ollama")
    for path in ["SECURITY.md", "docs/ENCRYPTION.md", "docs/HIPAA-SAFEGUARDS.md"]:
        check("search.sqlite" in doc(path), f"{path} must disclose the plaintext search.sqlite index")
    for path in ["PRIVACY.md", "TERMS.md", "SECURITY.md"]:
        text = without_setting_title(doc(path)).lower()
        check("icloud backup" not in text, f"{path} must not offer an iCloud backup")
        check("backup to your own" not in text, f"{path} must not describe an upload")
    check("does not back up your data on its own" not in terms, "TERMS.md says the app does not back up")
    for path in ["PRIVACY.md", "SECURITY.md", "TERMS.md", "docs/HIPAA-SAFEGUARDS.md"]:
        check(ci(doc(path), "Back Up Now"), f"{path} must describe Back Up Now")
    check("not connected to the app" not in security, "SECURITY.md says backup is not connected to the app")
    check("not connected to the user interface" not in doc("docs/HIPAA-SAFEGUARDS.md"),
          "docs/HIPAA-SAFEGUARDS.md says backup is not connected to the user interface")
    for path in ["PRIVACY.md", "SECURITY.md", "docs/HIPAA-SAFEGUARDS.md"]:
        check(ci(doc(path), "Restore from backup"), f"{path} must describe Restore from backup")
        check(not ci(doc(path), "no restore screen"), f"{path} says there is no restore screen")

    # ---- Support is private; the Terms name a governing law -------------------
    for path in ["TERMS.md", "PRIVACY.md", "docs/SETUP-GUIDE.md"]:
        text = doc(path)
        check(not ci(text, "open an issue"), f"{path} sends support to a public issue")
        check("github.com/mgwedd/aletheia/issues" not in text, f"{path} links the public issue tracker")
        check("support@astrealabs.com" in text, f"{path} lacks support@astrealabs.com")
    check("laws of the State of Wyoming" in terms, "TERMS.md lacks the governing law")
    check("Specify the governing jurisdiction" not in terms, "TERMS.md still has the jurisdiction placeholder")

    # ---- Feedback form, network helper, Export All Records --------------------
    check("astrealabs.com/feedback" in privacy, "PRIVACY.md must disclose the feedback form")
    check("Report a Bug" in doc("docs/SETUP-GUIDE.md"), "docs/SETUP-GUIDE.md lacks 'Report a Bug'")
    check("<key>com.apple.security.network.client</key>" not in doc("Sources/App/Resources/Aletheia.entitlements"),
          "the app entitlements grant network.client")
    for path in ["PRIVACY.md", "SECURITY.md", "docs/HIPAA-SAFEGUARDS.md"]:
        check(ci(doc(path), "helper"), f"{path} must describe the network helper")
        check("Hugging Face" in doc(path), f"{path} must name Hugging Face")
    check("network helper" in doc("docs/SETUP-GUIDE.md"), "docs/SETUP-GUIDE.md lacks 'network helper'")
    check("Export All Records" in doc("Sources/App/Views/SettingsView.swift"),
          "SettingsView.swift has no 'Export All Records' control")
    for path in ["PRIVACY.md", "SECURITY.md", "TERMS.md", "docs/HIPAA-SAFEGUARDS.md", "docs/SETUP-GUIDE.md"]:
        check("Export All Records" in doc(path), f"{path} lacks 'Export All Records'")

    # ---- Numbers quoted from the code (LegalTests pins the constants) ---------
    for path in ["SECURITY.md", "docs/ENCRYPTION.md"]:
        check("12 characters" in doc(path), f"{path} lacks '12 characters'")
    for path in ["SECURITY.md", "docs/HIPAA-SAFEGUARDS.md"]:
        check("15 minutes" in doc(path), f"{path} lacks '15 minutes'")

    # ---- Audit log and threat model -------------------------------------------
    for path in ["SECURITY.md", "docs/HIPAA-SAFEGUARDS.md"]:
        text = doc(path)
        check("audit_events" in text or ci(text, "tamper-evident"), f"{path} must describe the audit ledger")
        check("no tamper-evident" not in text, f"{path} contains 'no tamper-evident'")
        check("no integrity seal" not in text, f"{path} contains 'no integrity seal'")
    check("audit.log`, which" not in doc("docs/ENCRYPTION.md"), "docs/ENCRYPTION.md describes the old audit.log")
    check("docs/THREAT-MODEL.md" in security, "SECURITY.md must link docs/THREAT-MODEL.md")
    threat = doc("docs/THREAT-MODEL.md")
    for needle in ["Sources/NetworkHelper", "no network entitlement", "SHA-256", "FileVault", "Out of scope"]:
        check(needle in threat, f"docs/THREAT-MODEL.md lacks {needle!r}")

    # ---- The data folder stays on this Mac ------------------------------------
    folder_docs = ["README.md", "PRIVACY.md", "SECURITY.md"] + docs_md
    check("docs/SETUP-GUIDE.md" in folder_docs, "docs/SETUP-GUIDE.md is missing")
    for path in folder_docs:
        text = doc(path).lower()
        for phrase in ["opens in icloud drive", "suggests icloud", "suggests it", "icloud drive or any folder",
                       "icloud drive when it is available", "keep downloaded"]:
            check(phrase not in text, f'{path} contains "{phrase}"')
    check("Use the standard location" in doc("README.md"), "README.md lacks 'Use the standard location'")
    for path in ["Sources/App/Resources/Aletheia.entitlements", "Sources/App/Resources/AletheiaDev.entitlements"]:
        check("icloud" not in doc(path).lower(), f"{path} mentions iCloud")

    # ---- The company is the party ---------------------------------------------
    for phrase in ["Astrea Labs LLC, a Wyoming limited liability company", "12 months", "AS IS", "State of Wyoming"]:
        check(phrase in terms, f"TERMS.md lacks {phrase!r}")
    check(not ci(terms, "arbitration"), "TERMS.md mentions arbitration")
    check("Copyright (c) 2026 Astrea Labs LLC." in doc("LICENSE"), "LICENSE does not name Astrea Labs LLC")
    check("Astrea Labs LLC,\na Wyoming limited liability company" in privacy, "PRIVACY.md does not name the entity")
    check("Astrea Labs LLC" in doc("Sources/App/Resources/Info.plist"), "Info.plist does not name Astrea Labs LLC")
    for path in ["LICENSE", "TERMS.md", "PRIVACY.md", "SECURITY.md", "docs/HIPAA-SAFEGUARDS.md",
                 "Sources/App/Resources/Info.plist"]:
        check("Michael" not in doc(path), f"{path} names a person")
        check(not ci(doc(path), "the developer"), f"{path} says 'the developer'")
    for phrase in ["consent of every party", "24-word recovery key", "at least 12 characters", "plaintext files",
                   "macOS 14 or later", "installing App updates", "PDF", "Markdown", "calendar",
                   "Export All Records"]:
        check(phrase in terms, f'TERMS.md lacks "{phrase}"')
    for banned in ["pending counsel", "draft", "template"]:
        check(not ci(terms, banned), f'TERMS.md contains "{banned}"')

    # ---- Recording consent: CONSENT.md and the in-app guide agree -------------
    guide_paths = ["Sources/App/Views/ConsentGuideView.swift", "Sources/App/Services/ConsentGuideContent.swift"]
    guide = "\n".join(doc(p) for p in guide_paths)
    consent = doc("CONSENT.md")
    for path in ["CONSENT.md"] + guide_paths + docs_md:
        check(not ci(doc(path), "ollama"), f"{path} mentions Ollama")
    check("100%" not in guide, "the consent guide claims 100%")
    check("strictly" not in guide.lower(), "the consent guide says 'strictly'")
    check("never sent" not in guide, "the consent guide says 'never sent'")
    check("Time Machine" in guide, "the consent guide must mention Time Machine")
    key_phrases = [
        "California Penal Code §632",
        "Washington RCW 9.73.030",
        "Connecticut Gen. Stat. §52-570d",
        "not a complete list",
        "Before we start, I would like to record today's session so that I can write my clinical notes.",
        "The recording stays on my computer, where AI software turns it into a transcript and a draft of my notes.",
        "Do you agree to be recorded?",
        "you can ask me to pause or stop at any time",
    ]
    for name, text in [("CONSENT.md", consent), ("the consent guide", guide)]:
        check(ci(text, "examples"), f"{name} must call the statutes examples")
    flat_consent = consent.replace("\n> ", " ").replace("\n", " ").replace("  ", " ")
    for phrase in key_phrases:
        check(phrase in guide, f'the consent guide lacks "{phrase}"')
        check(phrase in flat_consent, f'CONSENT.md lacks "{phrase}"')

    # ---- Statements that used to be true and are not any more -----------------
    for path in ["PRIVACY.md", "SECURITY.md", "docs/HIPAA-SAFEGUARDS.md", "docs/ENCRYPTION.md", "docs/SETUP-GUIDE.md"]:
        check("can't verify" not in doc(path) and "cannot verify" not in doc(path), f"{path} says it can't verify")

    return list(failures)


def self_test(root: Path) -> None:
    """Copy the checked files to a scratch tree; the clean copy must pass and
    each planted defect must be caught."""
    files = ["README.md", "PRIVACY.md", "SECURITY.md", "TERMS.md", "CONSENT.md", "LICENSE",
             "Sources/App/Services/Legal.swift", "Sources/App/Services/BackupExclusion.swift",
             "Sources/App/Services/Crypto/AtRestEncryptionFeatureModule.swift",
             "Sources/App/Resources/Aletheia.entitlements", "Sources/App/Resources/AletheiaDev.entitlements",
             "Sources/App/Resources/Info.plist", "Sources/App/Views/SettingsView.swift",
             "Sources/App/Views/ConsentGuideView.swift", "Sources/App/Services/ConsentGuideContent.swift"]
    files += [f"docs/{p.name}" for p in (root / "docs").glob("*.md")]
    plants = [
        ("README.md", "\n\nRuns with Ollama.\n", "mentions Ollama"),
        ("docs/SETUP-GUIDE.md", "\n\nWe collect anonymous analytics.\n", "telemetry/analytics"),
        ("SECURITY.md", "\n\nThe app re-locks when it's hidden.\n", "re-locks when hidden"),
        ("TERMS.md", "\n\nThis draft is pending counsel.\n", '"draft"'),
    ]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        scratch = Path(tmp)
        for f in files:
            (scratch / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(root / f, scratch / f)
        if got := run(scratch):
            bad.append(f"the clean copy fails: {got}")
        for path, text, expected in plants:
            original = (scratch / path).read_text(encoding="utf-8")
            (scratch / path).write_text(original + text, encoding="utf-8")
            if not any(expected in f for f in run(scratch)):
                bad.append(f"planting {text.strip()!r} in {path} was not caught ({expected})")
            (scratch / path).write_text(original, encoding="utf-8")
        # The date check reads Legal.currentVersion from the Swift source.
        legal = scratch / "Sources/App/Services/Legal.swift"
        legal.write_text(re.sub(r'currentVersion = "[^"]+"', 'currentVersion = "1970-01-01"',
                                legal.read_text(encoding="utf-8")), encoding="utf-8")
        if not any("is older than" in f for f in run(scratch)):
            bad.append("an old Legal.currentVersion was not caught")
    if bad:
        for b in bad:
            print(f"check-docs self-test: {b}", file=sys.stderr)
        raise SystemExit(1)
    print("check-docs: self-test OK")


def main() -> None:
    args = sys.argv[1:]
    test = "--self-test" in args
    args = [a for a in args if a != "--self-test"]
    root = Path(args[0]) if args else Path(__file__).resolve().parent.parent
    if test:
        self_test(root)
        return
    found = run(root)
    for f in found:
        print(f"check-docs: {f}", file=sys.stderr)
    if found:
        raise SystemExit(1)
    print("check-docs: OK")


if __name__ == "__main__":
    main()
