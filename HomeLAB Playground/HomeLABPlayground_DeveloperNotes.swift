//
//  HomeLABPlayground_DeveloperNotes.swift
//  HomeLAB Playground
//
//  Developer Notes — persistent memory for whoever works on this next. Comments only; nothing here compiles to code.
//

// ============================================================================
// MARK: - PROJECT IDENTITY
// ============================================================================
//
//  Name:          HomeLAB Playground  (C-001: "HomeLAB playground", his word 2026-11-05)
//  Bundle ID:     com.homelab.playground
//  Platforms:     macOS 27, iOS / iPadOS 27 — one universal SwiftUI target ("i want it to be a universal app and a public repo")
//  Design record: amber sheet, section C (Download Manager), Desktop/Amber Sheets/Amber-Sheet-ALL-A-to-F-2026-11-09.html
//  Build number:  git rev-list --count HEAD via Scripts/ hooks — run Scripts/install-hooks.sh once per clone. Never hand-edit.
//  Ships agnostic: no hostnames, Mac names, accounts or folders are written into the app. "Lab B" and "MacBook" are
//  his names for the two roles; the app only ever says "this Mac" and shows the Mac's own name at runtime.

// ============================================================================
// MARK: - FILES (Mac only unless noted; everything below is #if os(macOS))
// ============================================================================
//
//  AppRole.swift          C-010 role (Send links / Download), RoleRunner starts/stops the downloader, LoginItem (C-012)
//  DownloadItem.swift     one queue line: a file, or an archive.org item waiting to be listed; SiteReport
//  DownloadQueue.swift    the engine: one file at a time, resume, retry forever with backoff, size + checksum, Queue.json
//  ResumingDownload.swift URLSession data task streaming onto <name>.part with Range; FileVerifier (CryptoKit MD5/SHA-1/SHA-256)
//  SiteCheck.swift        before a download: HEAD (type, size, last-modified, Accept-Ranges, digest headers) + 64-byte peek
//  ArchiveOrg.swift       archive.org link → metadata API → one file per line with size/md5/sha1 (C-003)
//  FolderAccess.swift     C-005 folder window at the last folder; C-016 security-scoped bookmarks; recent folders (≤ 8)
//  LinkService.swift      C-011 Bonjour _homelabplay._tcp; takes links, sends the live queue (C-014), carries notices (C-034)
//  MorningRestart.swift   C-033 5 AM pause → announce → quit and reopen (TestFlight gap when installed by TestFlight); DriveCheck (C-030/031)
//  DownloaderView.swift   the Mac window: role question, paste box, queue; HeaderView shared with SenderView
//  SettingsView.swift     role picker + Access rows (download folder, Open at Login, local network); on a sending Mac:
//                         Speak Alerts switch + Access rows (notifications, local network)
//  DownloaderLink.swift   C-021 sending Mac: NWBrowser for _homelabplay._tcp, one NWConnection, watch + add + controls
//  SenderView.swift       C-021 sending Mac's window: which Mac, notices (C-034), paste box + folder, live queue (C-014)
//  Notifier.swift         C-015 alerts on the sending Mac (finished / stalled / notices) + spoken line (default voice)
//  ContentView.swift      all platforms; iPhone/iPad show AboutView
//  HomeLAB Playground-Info.plist (repo root, merged into the generated Info.plist): NSBonjourServices

// ============================================================================
// MARK: - THE WIRE (downloading Mac ⇄ sending Mac, C-021)
// ============================================================================
//
//  Browse Bonjour for _homelabplay._tcp; connect TCP; one JSON object per line ("\n"):
//    → {"op":"add","link":"<links>"}  ← {"kind":"added","ok":Bool,"message":String}   (goes to the last folder picked on the downloading Mac)
//    → {"op":"queue"}                 ← {"kind":"queue","mac":…,"build":…,"items":[…],"notice":{"text","at"}?}
//    → {"op":"watch"}                 ← the queue message now and after every change (≤ 1 a second)
//  item: id, name, state (waiting|checking|downloading|verifying|retrying|done), received, size?, group?, folder,
//        note?, checked?, nextTry? (ISO 8601), finished?
//  Build 3 additions — backward compatible: every old message is unchanged, unknown keys are ignored, unknown ops get
//  no answer. The sending Mac shows a button only when the queue message's "ops" lists it (a build-2 downloading Mac
//  sends no "ops", so the sending Mac treats it as add/queue/watch only and shows no Cancel / Try Again / folder pick).
//    queue message also carries:
//      "ops":["add","add.folder","queue","watch","cancel","retry","cancelRest","clearFinished"]
//      "destination":{"path","name"}?   where a link without "folder" goes now (the last folder picked there)
//      "folders":[{"path","name"},…]     the downloading Mac's recent folders, newest first (≤ 8)
//    → {"op":"add","link":…,"folder":"<path>"}  ← "added" as before; the path must be one of "folders", and it becomes
//                                                 the last folder on the downloading Mac (C-005 "remembers your last pick")
//    → {"op":"cancel","id":"<item id>"}         ← {"kind":"result","op":"cancel","ok":Bool,"message":String}
//                                                 unfinished: canceled, part file deleted; done: removed from the list only
//    → {"op":"retry","id":"<item id>"}          ← result (only while the item is "retrying" — Try Again Now)
//    → {"op":"cancelRest","group":"<group>"}    ← result (every unfinished file of that archive.org item)
//    → {"op":"clearFinished"}                   ← result
//  The sending Mac sends "watch" first and everything else down the same connection; it reconnects every 5 s while
//  the downloading Mac is gone (5 AM restart) and keeps the last queue and notice on screen meanwhile.
//  No sign-in on the wire: any Mac on your home network can add links and cancel them. Fine for a home LAN; revisit
//  before anything wider.

// ============================================================================
// MARK: - REM HISTORY
// ============================================================================
//
//  2026-11-05  Build 1 — empty universal app, Scripts/ build-number hooks.
//  2026-11-09  Piece 1 of the C lines (C-020: "yes lock the plan" — "Build the Lab B side first and prove it on the
//              Tranzor Z download"): the downloading Mac. Role picker; download engine with resume, retry and a queue
//              kept on disk; archive.org items as separate files; size + checksum check; folder window at the last
//              folder with a kept bookmark; paste box; Bonjour service with the live queue; Open at Login; 5 AM restart
//              with the drive check and the network notices. Built and compiled only — not run, nothing downloaded yet.
//              Claude's calls the sheet didn't settle: one file at a time; an archive.org item goes into a subfolder
//              named after its title; only the uploader's own files ("original"), not archive.org's derived copies or
//              its bookkeeping files; a link sent from another Mac goes to the last folder picked on the downloading
//              Mac; retry waits 15 s doubling to 10 min, forever; a stall is 90 s with no bytes; a TestFlight copy
//              stays closed 5 minutes at the morning restart so TestFlight can install (Mediaworks' number).
//              Not in this piece: the sending Mac's window (C-021), the Safari Share menu (C-004, needs its own
//              extension target), notifications and the spoken line on the sending Mac (C-015).
//  2026-11-09  Piece 2 (C-021: "Then the MacBook side, for sending links and watching the queue"): the sending Mac.
//              Finds the downloading Mac by Bonjour (C-011), picks it by itself when there is one, asks you when there
//              are several and remembers your pick (no names written in). Paste box (C-004) with the folder it goes to
//              and a pick from the downloading Mac's recent folders. Live queue (C-014) with Cancel / Try Again Now /
//              Cancel the Rest / Clear Finished working over the wire. Alerts when a file finishes or stalls and for
//              the downloading Mac's notices, plus a spoken line if you turn it on (C-015). The 5 AM notices on screen
//              (C-034). Settings: Speak Alerts, Access rows for notifications and local network.
//              Claude's calls: a stall alert is a file going to "waiting to try again", at most once per file per
//              10 minutes; the last file of an archive.org item gives one "all N files are done" alert instead of its
//              own; the first queue heard after opening is never alerted on; a notice older than 10 minutes when first
//              heard is shown, not alerted; choosing a recent folder from the sending Mac makes it the downloading
//              Mac's last folder; alerts show as banners even while the app is in front; the app asks for
//              notifications once when the sending side starts. Built and compiled only — not run against a real
//              downloading Mac yet.
//              Still not in: Safari's Share menu (C-004) — needs a Share extension target, not added in this piece.
