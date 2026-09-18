# Changelog

All notable changes to Letter are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

How we maintain it:

- During development, add bullets under **[Unreleased](https://github.com/stalvatero/letter/compare/v1.0.0-rc.4...HEAD)**.
- On each release (rc or stable), rename that section to the version + date, and
copy a short summary into `data/io.github.stalvatero.Letter.metainfo.xml.in.in`
(`<releases>`, leave msgstr empty in po files — keep release notes in English)
and the GitHub Release notes.
- Prefer user-visible changes (features, fixes, translations). Skip internal
refactors unless they affect behaviour.



## [Unreleased](https://github.com/stalvatero/letter/compare/v1.0.0-rc.4...HEAD)


### Translations

- Added Brazilian Portuguese translation.



### Changed

- Compose no longer autosaves to Drafts every two minutes. Save with the toolbar button, or choose Save / Discard when closing; This fix avoid duplicates expecially with M365 accounts.



## [1.0.0-rc.4](https://github.com/stalvatero/letter/compare/v1.0.0-rc.3...v1.0.0-rc.4) - 2026-09-17



### Added

- Right-click a To/Cc recipient chip in the message view for **Write to**
  (new compose) or **Copy Email**.
- Open `.eml` / `message/rfc822` files in a read-only viewer (no reply, forward,
  or other actions). Letter can register as a handler for those MIME types.
- Context menu **Save as EML…** on a single message exports it to a file you choose.
- Compose **High priority** toggle sets Importance / X-Priority headers.
- Multi-select preview shows bulk action buttons (Archive, Move, Mark as Read /
  Unread, Delete) instead of only instructional text.
- Compose context menu **Paste and Match Style** (also Ctrl+Shift+V) pastes
clipboard text using the font and size you are already typing with.
- Preferences **Aggregate sound** (on by default): one beep for all new mail in
a check cycle instead of a beep per message.



### Changed

- Opening **Drafts** does a short server tip refresh (with a small cooldown) so
a just-saved draft appears in Letter without waiting for the next mail check.
- Large Archive / Sent folders no longer keep retrying endless server refreshes  
when Microsoft 365 Online Archive makes message counts drift.
- Context menu **Update Folder** runs a thorough server high priority align for that folder. 
- Compose image-size controls ignore images inside the signature (and quoted
  mail); the signature editor still offers resize for its own images.



### Fixed

- Typing a recipient address and pressing Space turns it into a chip (or takes
  the autocomplete suggestion); display names without `@` still accept spaces.
- Compose keeps a single Drafts copy per message: later autosaves replace the
previous revision instead of leaving duplicates, and closing after further
edits asks to save those changes again. Opening Drafts also rebuilds from
Camel when even a single new local UID is missing from the list.
- Bulk **Mark All as Read** no longer blocks Send or draft save: flag upload
pauses for outbound mail, can be cancelled mid-flight, then resumes with the
remaining dirty SEEN flags still durable on disk.
- Compose format bar now shows the font, size, and bold/italic/underline/strike
under the caret or selection. Dropdowns clear when the face is not in Letter’s
font list or when the selection mixes different fonts or sizes.
- Compose / Sent recipient chips no longer glue bare addresses into the next
`Name <email>` entry when the To list mixes plain emails and display names
(also repairs “Send again” and older mangled Sent headers when possible).
- Compose recipient field no longer storms the GDK frame clock with continuous
layout requests while typing addresses (WrapBox + expanding entry).



## [1.0.0-rc.3](https://github.com/stalvatero/letter/compare/v1.0.0-rc.2...v1.0.0-rc.3) - 2026-09-14



### Added

- Soft archive / move / copy / flag changes are written to an on-disk mutation
registry. Pending work stays durable across crash, offline use, and restarts
instead of living only in RAM.
- Compose autosave every 2 minutes into the account **Drafts** folder (local
Camel store; server upload follows the normal sync interval). Toast once per
compose window.
- Virtual **Outbox**: Send writes the message to disk first, then delivers on
an isolated retry pump (badge, Edit / Send Now / Cancel Send). Sending no
longer waits behind Archive body sync.



### Changed

- Opening a folder is cache-first (disk/Camel local); server header sync runs
on F5, the mail-check timer, scout, or when the local list is clearly
incomplete while online. Status “Updating…” stays for the open folder / F5.
- Large folders (Archive, Sent, custom bulk): scout uses short, widening
budgets instead of a full 90s `refresh_info` every cycle, with backoff after
a failed full attempt. Sent/Drafts also get a periodic tip refresh.
- Empty Trash / Junk and permanent deletes use Camel `synchronize` then
`expunge` where needed. Microsoft 365 repairs missing Trash/Junk folder type
flags and hard-deletes Junk via Trash.
- Archive / delete / flag apply in the UI immediately; Graph push waits for the
sync timer, F5, startup, or a timed quit flush so Send stays responsive.
- Recipient chips require a real `user@domain` address. Outbox surfaces the
first send failure immediately.
- Inline compose images (insert, drag-drop, clipboard paste) are sent as
`multipart/related` CID parts instead of raw `data:` URIs.
- Flatpak ships a minimal Evolution + `evolution-ews` stack so Microsoft 365
Graph mail works in the sandbox (bundle is larger). Host `evolution-ews`
remains useful for Calendar/Contacts. UI translations ship inside the
bundle; new Flatpak / first-sync strings translated for Italian and German.
- Folder pane shows live activity (Updating… / Sending… / Downloading…). Body
prefetch pauses when a send is waiting. Hung Graph folder refreshes are
time-bounded so they cannot block reading forever.



### Fixed

- Opening a folder no longer forces a server refresh on every click (that broke
offline browsing and cancelled work when switching folders).
- Startup no longer skips the first Inbox sync when opening a folder preempts
the folder-tree job.
- Microsoft 365 Archive moves no longer hang for minutes on one message;
Letter freezes the Camel folders around the transfer so moves finish in
seconds and can run in bulk.
- Microsoft 365 Empty Junk and permanent deletes from Trash no longer come
back after sync.
- Large Archive (and similar) folders no longer stay stuck on a stale local
header list when Camel already has many more UIDs; opening the folder
rebuilds the list.
- Sending could stick on “Sending…” forever while Archive body download held
Camel; send can now finish even when background work was stuck.
- Preferences “Download message bodies” applies to every folder, not only
Inbox.
- Flatpak Dependencies page correctly detects host `evolution-ews` and Sushi;
Online Accounts / Calendar / Contacts menu actions open the host apps over
D-Bus.
- Folders with unread/total hints but no local headers yet show an “aligning
local cache” wait state instead of looking empty during first sync.



## [1.0.0-rc.2](https://github.com/stalvatero/letter/compare/v1.0.0-rc.1...v1.0.0-rc.2) - 2026-09-09



### Added

- Compact “Important message” badge for high-priority mail (sender Importance);
list/thread icons only — no user toggle on Microsoft accounts.
- Localized search operators via gettext (`contains:` / `from:` / `to:` plus
Italian `contiene:` / `da:` / `a:` and German `enthält:` / `von:` / `an:`);
English operators always work.



### Changed

- AppStream release notes stay English in translations (leave msgstr empty) so
translators are not asked to update them on every release.



### Fixed

- Microsoft 365 bookmarks map to Outlook Flag (follow-up), not High Importance;
flag push uses Camel `folder.synchronize`, and marking read no longer wipes a
remote Flag.
- Meeting invitation times use the event timezone (no more +2h shift in Rome).
- Invitation UI strings are included in gettext again.
- Accept/Decline update the UI and move the invite to Trash immediately; calendar
sync continues in the background.



### Translations

- German UI completed (Christian Lauinger), including Gmail Labels, well-known
folder names, undo toasts, and cache-loading strings.



## [1.0.0-rc.1](https://github.com/stalvatero/letter/releases/tag/v1.0.0-rc.1) - 2026-09-08



### Added

- First Flatpak bundle for GitHub Releases (GNOME Platform 50; not on Flathub yet).
- Undo toast for archive, move, and trash.
- CI validation on Fedora 44.



### Changed

- Startup always opens Inbox for the last selected account (folder selection is
no longer restored).
- Cache-first folder trees and message lists for faster account switching.



### Fixed

- Folder-tree disk cache writes after the cache directory already exists.
- Thread focus after archiving a message inside a conversation.
- Localized well-known folder names (Drafts, Sent, …) in the UI locale.

