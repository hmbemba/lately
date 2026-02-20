# discard """
# nim c -d:ssl -d:release -r src/gld.nim
# nim c -d:ssl -d:ic -r src/gld.nim
# """

# gld.nim - Main CLI entry point
##
## `gld` with no args → interactive mode
## `gld i` / `gld interactive` → interactive mode
## All existing commands unchanged

import
    std/[
        os
        ,strutils
    ]

import
    ./src/help
    ,./src/cmds
    ,./src/cmd_accts
    ,./src/cmd_queue
    ,./src/cmd_post
    ,./src/cmd_interactive


proc main() =
    let args = commandLineParams()

    if args.len == 0:
        runInteractive()
        return

    let cmd = args[0].toLowerAscii
    let rest = if args.len > 1: args[1..^1] else: @[]

    case cmd

    # ─────────────────────────────────────────
    # Interactive mode (explicit)
    # ─────────────────────────────────────────
    of "i", "interactive":
        runInteractive()

    # ─────────────────────────────────────────
    # Core commands
    # ─────────────────────────────────────────
    of "init":
        runInit()
    of "profiles", "profile":
        runProfiles(rest)
    of "accounts", "acct", "accts":
        runAccounts(rest)
    of "uploads":
        runUploads(rest)
    of "upload":
        runUpload(rest)
    of "sched", "scheduled":
        runSched(rest)
    of "queue":
        runQueue(rest)

    # ─────────────────────────────────────────
    # Posting commands
    # ─────────────────────────────────────────
    of "post", "p":
        runPost(rest)

    # Platform shortcuts
    of "x", "twitter", "tw":
        runX(rest)
    of "threads", "th":
        runThreads(rest)
    of "instagram", "ig", "insta":
        runInstagram(rest)
    of "linkedin", "li":
        runLinkedIn(rest)
    of "facebook", "fb":
        runFacebook(rest)
    of "tiktok", "tt":
        runTikTok(rest)
    of "bluesky", "bsky":
        runBluesky(rest)
    of "youtube", "yt":
        runYouTube(rest)

    # ─────────────────────────────────────────
    # Help
    # ─────────────────────────────────────────
    of "help", "-h", "--help":
        printHelp()

    else:
        echo "Unknown command: " & cmd
        echo "Run 'gld --help' or just 'gld' for interactive mode."


when isMainModule:
    main()