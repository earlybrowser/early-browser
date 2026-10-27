# Import from another browser

Available from **File → Import from Another Browser…**, **Settings → Sessions**,
and the welcome screen. Imports stay on this Mac and never change the source.
Available in Early 0.1.4 and later.

## Choose, preview, then import

1. Choose a browser; there is no automatic default. Use **Other Chromium browser**,
   **Other Firefox browser**, or **Other browser** for an unlisted source. The sheet
   gives short instructions for the selected browser. Firefox/Zen point to the
   ↑↓ toolbar button in Manage Bookmarks for HTML export.
   - Safari: export Bookmarks and History, unzip the export, then select the
     bookmarks HTML and history JSON together in one file picker. One preview
     covers all selected files, including a separate Reading List HTML if present.
     Only bookmarks, Reading List and history enter this route;
     password CSVs, extension lists and credit cards are rejected.
   - Chromium: import an exported bookmarks file, or choose the browser's saved-data
     folder to import **history only**. This folder route does not read bookmarks
     or sessions. Dia uses **Other Chromium browser**.
   - Firefox/Zen: keep both exported-file and full browser-data-folder routes.
     Zen's folder route preserves its supported workspace organization.
   - Arc: select its saved sidebar file or data folder.
   Selecting a browser alone grants no access and imports nothing. A data folder
   is the browser's existing saved data on this Mac, read without changing it.
2. Expand the preview, search by name/address, and check individual items or
   branches. Mixed checkboxes show partial selection; searching and collapsing
   retain it. History and open tabs start unchecked.
3. Choose existing or new profiles and Spaces. Source profiles stay separate by
   default, even when their names match. Combine them explicitly into an existing
   profile or one new profile. One profile choice applies to all its Spaces.
   Shared collections have explicit receiving profiles, with optional overrides
   for individual folders. Check the review before applying.
4. Review counts, destinations, unsupported items and any explicit deep-folder
   flattening. Import only after confirming.
5. Use **Undo Import** in Settings → Sessions, including after restarting Early.

There is no compulsory Imported Bookmarks folder. Loose bookmarks become pins
in the chosen Space; selected folders retain their necessary ancestors and order.
Existing items keep their visual order and imports append after them. Repeating
bookmarks deliberately creates another selected copy; deselect unwanted copies.
Matching source visits are deduplicated across imports. Imported pins are metadata,
not running pages, and previewing/importing does not fetch favicons or websites.

## Supported source formats

| Source | What transfers | Verification and limits |
| --- | --- | --- |
| Any browser with a Netscape bookmarks HTML export | Titles, HTTP/HTTPS addresses, nested/empty folders and order | Synthetic malformed/unclosed-tag, Unicode and unsafe-link fixtures. Browser brand does not matter; arbitrary proprietary formats are not implied. |
| Chromium-family profiles, including compatible Chrome, Edge, Brave, Vivaldi, Opera and Dia | Bookmark export files; the Chromium folder route reads real visits from `History` SQLite only, with separate profiles and names from `Local State` where present | Chromium's public schema, synthetic database/WAL fixtures, and a synthetic Dia 1.54.2 profile created by that browser. No credential database or Keychain decryption. |
| Unencrypted Chromium SNSS v3 sessions | Current URLs/titles, pin state, tab groups as ordinary folders, ungrouped Today tabs | Command framing/navigation-prefix fixtures checked against Chromium source. SNSS v5 is encrypted and refused. If `Sessions_Encrypted` exists, adjacent older cleartext sessions are not mistaken for current tabs. Save groups/tabs as bookmarks and export HTML instead. |
| Firefox-family profiles/exports | `places.sqlite` bookmarks/history, Firefox bookmarks JSON, session JSON or Mozilla JSONLZ4; current tabs, groups, pins and separate container destinations | Public Mozilla format and synthetic schema/session fixtures. Read `sessionstore.jsonlz4` or the current recovery file. Closed/private windows and back/forward/form state do not transfer. |
| Safari exported bookmarks HTML and history JSON selected together | Bookmarks, Reading List as an ordinary folder, latest known visit per history item | Apple's documented schema v1 and synthetic localized stored/deflated ZIP fixtures. File names need not be English. The existing ZIP parser and its tests are retained; this change does not investigate ZIP selection. Only known timestamps transfer; aggregate visit counts never become invented visits. |
| Zen workspace JSON/JSONLZ4 or profile folder | Workspaces, Essentials, pins, nested folders, mixed folder/tab order, available Today tabs and containers | Synthetic profile created and captured from Zen 1.23.4b, plus container/predecessor-field fixtures and public source checks. Containers become separate Early profiles by default; Essentials retain their recorded context, with explicit shared-copy routing when verified by the source preference. |
| Arc `StorableSidebar.json` | Known alternating-dictionary sidebar schema: Spaces, available profile IDs, Favorites, pins, folders and Today tabs | **Experimental**, as agreed: synthetic schema fixtures, no current Arc installation verified. Unknown schemas fail with an HTML-export alternative. Review mappings carefully. Missing profile IDs stay isolated rather than guessing shared accounts. |
| Dia proprietary workspace organization | No unverified native workspace reader | Its Chromium bookmarks/history are verified; use HTML for other organization. The preview states this limit. |

Safari histories remain separate by source file, with profile names suggested
from filename suffixes. The unsuffixed history file has an editable “Safari
profile” name; its real name cannot be recovered from the documented metadata.
Renamed/localized or same-named exports can be regrouped explicitly. Bookmarks
and Reading List appear once as shared collections, without an extra source
profile. A single profile receives them by default; multiple profiles require
an explicit choice. “Choose destinations for individual folders” lets Personal,
Work and other Favorites folders go to different profiles, retaining ancestors.
Copies are independent after import; live cross-profile bookmark sharing does
not transfer. An HTML export cannot supply live tabs, groups or sign-ins absent
from the export. The existing ZIP reader is unchanged; Safari's named UI uses
the unpacked multi-file route.

Firefox/Zen container IDs are scoped to their source profile. Matching IDs from
different profiles never merge. Within one profile, places/session files share
the same context identities, and containers.json supplies descriptive names.
When a verified history schema records positive userContextId values, visits
follow those contexts. Older/default-valued history can include visits whose
original context was never recorded, even after a schema upgrade. Such history
requires one explicit destination, starts unchecked, and is never attributed by
URL. Profile-wide bookmarks can be copied to explicitly selected contexts.

Zen workspaces using the same context become Spaces in the same Early profile.
Mixed-context workspaces become separate Spaces in the corresponding profiles,
with a review notice; empty workspaces retain their recorded default container.
Mirrored tabs are deduplicated by verified source identity, preserving intentional
URL copies. Conflicting mirrored identities require a fresh source snapshot.
When the folder's prefs.js explicitly disables separate Essentials, those
Essentials receive shared-collection routing. Only that boolean preference is
retained; other preference values do not enter the import model. Without that
evidence, Essentials keep their recorded context. Password-vault sharing and
container extension routing rules do not transfer.

Live folders and split groups become ordinary snapshots. Supported named colors
and SF Symbol icons transfer where present; gradients, custom source icons,
Easels/notes/Boosts and unsupported integrations do not. Grouped open tabs become
saved pins because Early folders contain pins. Ungrouped Today tabs belong to one
destination window per profile, not every open window. Existing windows, current
selections and live WebViews are retained.

## Privacy and limits

Passwords retain their separate **Settings → Passwords → Import CSV** flow.
Cookies, signed-in sessions, authentication tokens, browser settings and extensions
are excluded. New profiles require signing in again. Private profiles are never
import destinations. The source files are read only while user-selected access is
held; no permanent source permission/bookmark is kept.

- HTTP/HTTPS only. Browser-internal URLs, bookmarklets, local-file links and URLs
  containing credentials are skipped with a preview notice.
- Input/decompressed archive: 64 MiB; 512 ZIP entries; 500:1 expansion limit;
  no traversal paths, symlinks, encrypted ZIPs or unchecked extraction.
- Up to 80,000 normalized records. History previews at most 50,000 known visits
  within Early's one-year retention period; larger databases show this limit.
  Future timestamps are excluded. Direct SQLite sources are capped at 1 GiB and
  copied with the online backup API to a private, temporary coherent snapshot.
  Busy sources give a close-the-source-browser/export alternative.
- Result must fit Early's portable archive limits: 32 profiles, 20,000 tab records
  across windows, and a 16 MiB encoded archive.
- Root folder depth is 0, with eight nested levels beneath it. Deeper imports name
  the branch and require explicit flattening or deselection. Legacy deeper Early
  sessions remain readable and can be moved upward without silent flattening.
  Folder backgrounds are limited to the outer group and current folder;
  intermediate levels retain their indentation and drag/hit geometry.
- Parsing and database work run off the main thread. Imports bulk-create metadata
  and do not create WebViews. Temporary source snapshots/access are released on
  success, failure and cancellation.

## Durable saving and Undo

Early saves a recovery archive before applying, keeping the latest five backups.
That archive excludes history. A separate durable journal and tagged history rows
coordinate the import across the workspace and profile history databases. The
workspace's atomic batch marker is the commit point: interrupted pre-commit imports
roll history back; committed imports remain available for Undo. Success appears
only after the workspace and selected history have been saved.

Undo removes unchanged imported records and only the visits actually inserted by
that batch. It identifies edited/active pages and folders with later contents
before confirmation and preserves them by default. Profiles are retained because
they may now contain passwords or website data; those stores are never deleted by
Undo. Interrupted cleanup can be retried and is recovered on next launch. Local
journal markers are excluded from portable Early exports. Up to 128 undo batches
are kept; undo an older batch before adding another when the limit is reached.

Deleting a profile removes its history and prunes that profile's portion from
import records. Entirely obsolete records and workspace markers disappear;
mixed imports keep their surviving portions and Undo. Moved/edited items in
remaining profiles are preserved. Cleanup starts only after the profile deletion
is saved, is reconciled again on startup, and reports disk failures for retry.
Old journals without explicit folder ownership remain readable. Stale Undo
confirmations consult the current journal and cannot recreate deleted profiles
or missing history files.

## Validation

Package tests exercise format boundaries, selections/mixed states, containers and
profile isolation, eight-level and legacy folder behavior, ordering, history epochs
and WAL snapshots, duplicate visits, four-profile Safari/Firefox fixtures, ambiguous names,
shared folder routing/copy limits, old/new history schemas, mirrored Zen tabs,
profile deletion and journal-write failures, malformed/archive attacks, cancellation,
failed backup/session writes, recovery, restart-safe selective Undo, and bulk
5,000-page import/portable round trips. Application tests keep two live WebViews
and selections unchanged through import/undo. Native UI coverage compiles locally;
execution of the wizard/keyboard/deep-folder tests belongs to CI only.

Local verification on 2026-10-27: all **789 package tests** passed with
`swift test --no-parallel` (199 WebKit, 353 Core, 237 application tests).
Debug `build-for-testing` and Release `build` both succeeded. UI tests were
compiled only; running them on CI remains required before merging.

Fixture provenance is in [the fixture notes](../Tests/EarlyCoreTests/Fixtures/BrowserImport/README.md).

Primary references:

- [Apple Safari export schema](https://developer.apple.com/documentation/SafariServices/importing-data-exported-from-safari).
- [SQLite online backup](https://www.sqlite.org/backup.html).
- [Chromium bookmarks codec](https://chromium.googlesource.com/chromium/src/+/HEAD/components/bookmarks/browser/bookmark_codec.cc),
  [session commands](https://chromium.googlesource.com/chromium/src/+/HEAD/components/sessions/core/session_service_commands.cc),
  [navigation serialization](https://chromium.googlesource.com/chromium/src/+/HEAD/components/sessions/core/serialized_navigation_entry.cc),
  [encrypted command storage](https://chromium.googlesource.com/chromium/src/+/HEAD/components/sessions/core/command_storage_backend.cc).
- [Mozilla session implementation](https://github.com/mozilla-firefox/firefox/blob/main/browser/components/sessionstore/SessionStore.sys.mjs).
- [Safari profile sharing](https://support.apple.com/en-us/105100).
- [Mozilla history schema](https://github.com/mozilla-firefox/firefox/blob/main/toolkit/components/places/nsPlacesTables.h),
  [history migration](https://github.com/mozilla-firefox/firefox/blob/main/toolkit/components/places/Database.cpp).
- [Zen workspace and container model](https://docs.zen-browser.app/user-manual/workspaces),
  [mirrored windows](https://docs.zen-browser.app/user-manual/window-sync).
- [Zen session manager](https://github.com/zen-browser/desktop/blob/ed78bebf6aecdc80e54bbc6de4667d873d257a44/src/zen/sessionstore/ZenSessionManager.sys.mjs).
