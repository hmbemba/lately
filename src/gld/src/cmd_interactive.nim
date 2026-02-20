# src/gld/cmd_interactive.nim
##
## Interactive mode for GLD CLI
##
## Launched via:
##   gld              (no args)
##   gld i
##   gld interactive
##
## Provides a guided wizard for all common workflows,
## eliminating the need to memorize flags or subcommands.

import
    std/[
        strformat
        ,strutils
        ,sequtils
        ,options
        ,asyncdispatch
        ,os
        ,tables
    ]

import
    ic
    ,rz
    ,termui

import
     ../../lately/accounts as late_accounts
    ,../../lately/profiles as late_profiles
    ,../../lately/posts as late_posts
    ,../../lately/queue as late_queue
    ,./store_config
    ,./store_uploads
    ,./types
    ,./cmd_post
    ,./cmd_queue
    ,./cmd_accts
    ,./cmds
    ,./help


# ============================================
# Constants
# ============================================

const
    ActionPost          = "Create a post"
    ActionQueue         = "Manage queue"
    ActionAccounts      = "View connected accounts"
    ActionProfiles      = "Switch / view profiles"
    ActionScheduled     = "View scheduled posts"
    ActionUploads       = "View uploaded media"
    ActionInit          = "Configure (gld init)"
    ActionHelp          = "Help"
    ActionQuit          = "Quit"

    PostPublish         = "Publish now"
    PostQueue           = "Add to queue"
    PostSchedule        = "Schedule for later"
    PostDraft           = "Save as draft"

    QueueView           = "View queue slots"
    QueuePreview        = "Preview upcoming slots"
    QueueNext           = "Next available slot"
    QueueCreate         = "Create new queue"
    QueueBack           = "Back"

    AcctList            = "List accounts"
    AcctHealth          = "Account health check"
    AcctBack            = "Back"

# ============================================
# Status / Welcome
# ============================================

proc printWelcome(conf: GldConfig) =
    echo ""
    echo "  ✨ GLD - Social Media from the Terminal"
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if conf.apiKey.strip.len > 0:
        let masked = conf.apiKey[0 .. min(7, conf.apiKey.high)] & "..."
        echo &"  🔑  API Key: {masked}"
    else:
        echo "  ⚠️   No API key configured. Run 'gld init' first."

    if conf.profileId.isSome:
        echo &"  👤  Profile: {conf.profileId.get}"

    echo ""


# ============================================
# Interactive Post Flow
# ============================================

proc interactivePost(conf: GldConfig) =
    let apiKey = requireApiKey(conf)

    # 1. Pick profile (if multiple exist)
    var profileId = conf.profileId

    let profRes = waitFor late_profiles.listProfiles(apiKey)
    if profRes.ok and profRes.val.profiles.len > 1:
        let profiles = profRes.val.profiles
        var opts: seq[string]
        for p in profiles:
            let marker = if conf.profileId.isSome and conf.profileId.get == p.id: " ★" else: ""
            opts.add &"{p.name}{marker}"

        let picked = termuiSelect("Which profile?", opts)

        for i, o in opts:
            if picked == o:
                profileId = some profiles[i].id
                break

    # 2. Fetch connected accounts
    let acctRes = waitFor getConnectedPlatforms(apiKey, profileId)
    acctRes.isErr:
        echo &"❌ {acctRes.err}"
        return

    let available = acctRes.val
    if available.len == 0:
        echo "❌ No connected accounts found."
        echo "   Connect accounts at: https://getlate.dev"
        return

    # 3. Select platforms
    let selected = selectPlatformsInteractive(available)
    if selected.len == 0:
        echo "No platforms selected."
        return

    let platforms = selected.mapIt(it.platform)

    # 4. Post text
    var postText = termuiAsk("Post text:")

    if postText.strip.len == 0:
        echo "No text entered. Aborting."
        return

    # 5. Character limit warnings
    for plat in platforms:
        if cmd_post.PlatformCharLimits.hasKey(plat):
            let limit = cmd_post.PlatformCharLimits[plat]
            if postText.len > limit:
                let display = cmd_post.PlatformDisplayNames.getOrDefault(plat, plat)
                echo &"⚠️  Text ({postText.len} chars) exceeds {display} limit ({limit})"

    # 6. Media (optional)
    var mediaFiles: seq[string]

    let wantsMedia = termuiConfirm("Attach media files?")
    if wantsMedia:
        let paths = termuiAsk("File paths (comma-separated):").strip
        if paths.len > 0:
            mediaFiles = cmd_post.parseUserFileList(paths)
            for f in mediaFiles:
                if not fileExists(f):
                    echo &"⚠️  File not found: {f}"
                    mediaFiles = mediaFiles.filterIt(it != f)

    # Enforce media for platforms that require it
    if not ensureMediaInteractive(platforms, mediaFiles):
        return

    # 7. Post mode
    let modeChoice = termuiSelect("How should this be posted?", @[
        PostPublish
        ,PostQueue
        ,PostSchedule
        ,PostDraft
    ])

    var
        isDraft      = false
        useQueue     = false
        scheduledFor = none string

    case modeChoice
    of PostDraft:
        isDraft = true
    of PostQueue:
        useQueue = true
    of PostSchedule:
        let timeStr = termuiAsk("Schedule time (ISO 8601, e.g. 2025-06-15T10:00:00Z):")
        if timeStr.strip.len == 0:
            echo "No time entered. Aborting."
            return
        scheduledFor = some timeStr.strip
    of PostPublish:
        discard
    else:
        discard

    # 8. Confirm
    let confirmed = confirmPost(
        text          = postText
        ,platforms    = platforms
        ,mediaFiles   = mediaFiles
        ,isDraft      = isDraft
        ,scheduledFor = scheduledFor
        ,useQueue     = useQueue
    )

    if not confirmed:
        echo "Cancelled."
        return

    # 9. Execute
    var accountMap: Table[string, string]
    for s in selected:
        accountMap[s.platform] = s.accountId

    let params = PostParams(
        text         : some postText
        ,platforms   : platforms
        ,mediaFiles  : mediaFiles
        ,scheduledFor: scheduledFor
        ,isDraft     : isDraft
        ,useQueue    : useQueue
        ,title       : none string
        ,tags        : @[]
        ,hashtags    : @[]
        ,rawMode     : false
        ,dryRun      : false
    )

    let res = waitFor executePost(
        apiKey      = apiKey
        ,profileId  = profileId
        ,params     = params
        ,accountMap = accountMap
    )

    res.isErr:
        icr res.err
        echo &"❌ Failed to create post: {res.err}"
        return

    echo ""
    let mode = getPostMode(params)

    case mode
    of pmQueue:
        echo "✅ Queued for posting!"
    of pmSchedule:
        echo "✅ Scheduled!"
    of pmDraft:
        echo "✅ Draft saved!"
    of pmPublishNow:
        echo "✅ Post created!"

    echo "   ID: " & res.val.post.id

    if res.val.post.status.isSome:
        echo "   Status: " & res.val.post.status.get

    if mode == pmPublishNow and res.val.post.platforms.isSome:
        for p in res.val.post.platforms.get:
            if p.platformPostUrl.isSome:
                echo "   🔗 " & p.platformPostUrl.get

    if mode == pmQueue:
        tryPrintNextQueueSlot(apiKey, profileId)


# ============================================
# Interactive Queue Flow
# ============================================

proc interactiveQueue(conf: GldConfig) =
    let action = termuiSelect("Queue actions:", @[
        QueueView
        ,QueuePreview
        ,QueueNext
        ,QueueCreate
        ,QueueBack
    ])

    case action
    of QueueView:
        runQueue(@[])
    of QueuePreview:
        runQueue(@["preview"])
    of QueueNext:
        runQueue(@["next"])
    of QueueCreate:
        # Guided queue creation
        let apiKey = requireApiKey(conf)
        let profileId =
            if conf.profileId.isSome: conf.profileId.get
            else:
                echo "❌ No profile configured. Run: gld init"
                return

        let name = termuiAsk("Queue name:", defaultValue = "My Queue")
        let tz   = termuiAsk("Timezone:", defaultValue = "America/New_York")

        echo ""
        echo "Add time slots (day:HH:MM format)."
        echo "Days: 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat"
        echo "Example: 1:09:00 = Monday 9:00 AM"
        echo ""

        var slots: seq[late_queue.queue_slot]
        var addMore = true

        while addMore:
            let slotStr = termuiAsk("Slot (day:HH:MM):")
            let parts = slotStr.strip.split(":")
            if parts.len >= 2:
                try:
                    let day = parseInt(parts[0])
                    let time = parts[1 .. ^1].join(":")
                    slots.add late_queue.qSlot(day, time)
                    echo &"  ✓ Added: day {day} at {time}"
                except ValueError:
                    echo "  ⚠️  Invalid format. Use day:HH:MM (e.g., 1:09:00)"
            else:
                echo "  ⚠️  Invalid format. Use day:HH:MM (e.g., 1:09:00)"

            addMore = termuiConfirm("Add another slot?")

        if slots.len == 0:
            echo "No slots added. Aborting."
            return

        let makeActive = termuiConfirm("Activate this queue?")

        # Confirm
        echo ""
        echo &"Creating queue '{name}' in {tz} with {slots.len} slot(s)"

        if not termuiConfirm("Create?"):
            echo "Cancelled."
            return

        let res = waitFor late_queue.createQueue(
            api_key    = apiKey
            ,profileId = profileId
            ,name      = name
            ,timezone  = tz
            ,slots     = slots
            ,active    = some makeActive
        )

        res.isErr:
            icr res.err
            echo &"❌ Failed to create queue."
            return

        if res.val.message.isSome:
            echo "✅ " & res.val.message.get

    of QueueBack:
        return
    else:
        return


# ============================================
# Interactive Accounts Flow
# ============================================

proc interactiveAccounts(conf: GldConfig) =
    let action = termuiSelect("Account actions:", @[
        AcctList
        ,AcctHealth
        ,AcctBack
    ])

    case action
    of AcctList:
        runAccounts(@[])
    of AcctHealth:
        runAccounts(@["--health"])
    of AcctBack:
        return
    else:
        return


# ============================================
# Main Loop
# ============================================

proc runInteractive*() =
    var conf = loadConfig()
    printWelcome(conf)

    # If no API key, push to init immediately
    if conf.apiKey.strip.len == 0:
        echo "Let's get you set up first."
        echo ""
        cmds.runInit()
        conf = loadConfig()
        if conf.apiKey.strip.len == 0:
            echo "Setup incomplete. Run 'gld init' when ready."
            return

    var running = true

    while running:
        let action = termuiSelect("What would you like to do?", @[
            ActionPost
            ,ActionQueue
            ,ActionAccounts
            ,ActionProfiles
            ,ActionScheduled
            ,ActionUploads
            ,ActionInit
            ,ActionHelp
            ,ActionQuit
        ])

        case action
        of ActionPost:
            try:
                interactivePost(conf)
            except CatchableError as e:
                echo &"❌ {e.msg}"

        of ActionQueue:
            try:
                interactiveQueue(conf)
            except CatchableError as e:
                echo &"❌ {e.msg}"

        of ActionAccounts:
            try:
                interactiveAccounts(conf)
            except CatchableError as e:
                echo &"❌ {e.msg}"

        of ActionProfiles:
            try:
                let apiKey = requireApiKey(conf)
                let profRes = waitFor late_profiles.listProfiles(apiKey)
                if not profRes.ok:
                    echo &"❌ Failed to list profiles: {profRes.err}"
                else:
                    let profiles = profRes.val.profiles
                    if profiles.len == 0:
                        echo "No profiles found."
                    else:
                        var opts: seq[string]
                        for p in profiles:
                            let marker = if conf.profileId.isSome and conf.profileId.get == p.id: "★ " else: "  "
                            opts.add &"{marker}{p.name}  ({p.id})"
                        opts.add "⬅️  Back"

                        let picked = termuiSelect("Select a profile to switch to:", opts)

                        if picked != "⬅️  Back":
                            for i, p in profiles:
                                if picked.contains("(" & p.id & ")"):
                                    conf.profileId = some p.id
                                    saveConfig(conf)
                                    echo &"✅ Switched to: {p.name}"
                                    break
            except CatchableError as e:
                echo &"No profiles found."

        of ActionScheduled:
            try:
                cmds.runSched(@[])
            except CatchableError as e:
                echo &"❌ {e.msg}"

        of ActionUploads:
            try:
                cmds.runUploads(@[])
            except CatchableError as e:
                echo &"❌ {e.msg}"

        of ActionInit:
            try:
                cmds.runInit()
                conf = loadConfig()  # reload after re-init
            except CatchableError as e:
                echo &"❌ {e.msg}"

        of ActionHelp:
            help.printHelp()

        of ActionQuit:
            echo "👋 See you!"
            running = false

        else:
            running = false

        if running:
            echo ""