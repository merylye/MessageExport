# Download My Messages

Export your iMessages and SMS to CSV and JSON. You choose which conversations to export and a separate date range for each one. Everything runs on your own computer. Nothing is uploaded.

There are two versions:

- **Mac app** (`mac/`): native SwiftUI app. Reads the Messages app's database on your Mac, or an iPhone backup made in Finder.
- **Cross-platform app** (`desktop/`, coming next): runs on Mac and Windows.

## Where your messages come from

- **This Mac:** if Messages on your Mac shows your history (Messages in iCloud turned on, and Text Message Forwarding for SMS), the app can read it directly.
- **iPhone backup:** if your history is only on your iPhone, connect it to your Mac, open Finder, select the iPhone, turn off "Encrypt local backup", and click "Back Up Now". Then choose the backup in the app. (Encrypted backups aren't supported yet.)

iPhone apps can't read Messages, so an export always goes through a computer.

## Using the Mac app

1. Download `Download My Messages.zip` from the latest build (Actions tab > Mac app > Artifacts), unzip it, and move the app to Applications.
2. The first time, right-click the app and choose **Open** (the app isn't signed with a paid Apple Developer ID, so macOS warns you).
3. Allow **Full Disk Access** when the app asks (System Settings > Privacy & Security > Full Disk Access). macOS requires this for any app that reads Messages.
4. Allow **Contacts** access if you want names instead of phone numbers.
5. Tick the conversations you want, set a date range for each (presets or a custom calendar range), choose CSV and/or JSON, and click **Export…**.

When "Copy attachments" is off, the export records only each attachment's file type. When it's on, photos and files are copied into an `attachments/` folder next to the CSV/JSON. Attachments stored only in iCloud are marked as missing.

## Export format

One file per conversation, plus `export-summary.json` listing each conversation and its date range.

CSV columns: `conversation, timestamp, sender, sender_handle, is_from_me, text, attachments, reactions, reply_to, edited, service, message_id`. The CSV has a UTF-8 byte-order mark so Excel shows emoji correctly.

JSON has the same fields per message, with attachments and reactions as nested lists, plus the participant list and the date range used.

Tapbacks (loved, liked, etc.) are attached to the message they react to, and removed tapbacks are dropped. Group events (renames, people joining) are left out.

## Building the Mac app yourself

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```
cd mac
swift run SelfTest          # checks against a fake Messages database
./scripts/build-app.sh      # builds mac/build/Download My Messages.app
```

After rebuilding, macOS may ask you to grant Full Disk Access again, because the app's ad-hoc signature changes with each build.
