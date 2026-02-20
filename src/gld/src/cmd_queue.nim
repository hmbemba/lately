# src/gld/cmd_queue.nim

import
    std/[
        strformat
        ,strutils
        ,sequtils
        ,options
        ,asyncdispatch
    ]

import
    ic
    ,rz

import
    ../../late_dev/queue as late_queue
    ,store_config
    ,types


# --------------------------------------------
# Helpers
# --------------------------------------------

proc pickArg(
    args                : seq[string]
    ,key                : string
)                       : Option[string] =
    ## Supports:
    ##   --key=value
    ##   --key value
    for i, a in args:
        if a.startsWith(key & "="):
            return some a.split("=", 1)[1]
        if a == key and i + 1 < args.len:
            return some args[i + 1]
    return none string


proc hasFlag(
    args                : seq[string]
    ,key                : string
)                       : bool =
    result = args.anyIt(it == key)


proc optStr[T](
    v                   : Option[T]
)                       : string =
    if v.isSome: $v.get else: ""


proc dayName(d: int): string =
    case d
    of 0: "Sun"
    of 1: "Mon"
    of 2: "Tue"
    of 3: "Wed"
    of 4: "Thu"
    of 5: "Fri"
    of 6: "Sat"
    else: "?"


# --------------------------------------------
# Help
# --------------------------------------------

proc printQueueHelp*() =
    echo "gld queue - Manage posting queue schedules"
    echo ""
    echo "Usage:"
    echo "  gld queue                      List default queue slots"
    echo "  gld queue --all                List all queues for profile"
    echo "  gld queue --id <queueId>       Show specific queue"
    echo "  gld queue preview              Preview upcoming posting slots"
    echo "  gld queue next                 Get next available slot"
    echo "  gld queue create               Create a new queue (interactive)"
    echo "  gld queue delete --id <id>     Delete a queue"
    echo ""
    echo "Options:"
    echo "  --profile <id>     Override profile id"
    echo "  --id <queueId>     Target specific queue"
    echo "  --all              Show all queues (list mode)"
    echo "  --raw              Print raw JSON response"
    echo "  --count <n>        Number of slots to preview (default: 10)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  gld queue                      # Show default queue"
    echo "  gld queue --all                # Show all queues"
    echo "  gld queue preview --count 20   # Preview next 20 slots"
    echo "  gld queue next                 # Get next available slot"
    echo "  gld queue delete --id abc123   # Delete queue"
    echo ""


# --------------------------------------------
# Render functions
# --------------------------------------------

proc renderQueue(q: late_queue.queue) =
    let
        name      = if q.name.isSome: q.name.get else: "(unnamed)"
        tz        = if q.timezone.isSome: q.timezone.get else: "(no timezone)"
        active    = if q.active.isSome: (if q.active.get: "yes" else: "no") else: "?"
        isDefault = if q.isDefault.isSome and q.isDefault.get: " (default)" else: ""

    echo fmt"Queue: {name}{isDefault}"
    echo fmt"  id       : {q.id}"
    echo fmt"  timezone : {tz}"
    echo fmt"  active   : {active}"

    if q.slots.isSome and q.slots.get.len > 0:
        echo "  slots:"
        for s in q.slots.get:
            echo fmt"    {dayName(s.dayOfWeek):<3} {s.time}"
    else:
        echo "  slots: (none)"

    if q.createdAt.isSome:
        echo fmt"  created  : {q.createdAt.get}"
    if q.updatedAt.isSome:
        echo fmt"  updated  : {q.updatedAt.get}"


proc renderQueues(queues: seq[late_queue.queue]) =
    if queues.len == 0:
        echo "(no queues)"
        return

    for i, q in queues:
        if i > 0:
            echo ""
        renderQueue(q)


proc renderPreview(resp: late_queue.queue_preview_resp) =
    if resp.timezone.isSome:
        echo fmt"Timezone: {resp.timezone.get}"
        echo ""

    if resp.slots.isNone or resp.slots.get.len == 0:
        echo "(no upcoming slots)"
        return

    echo "Upcoming Slots:"
    echo "  DateTime                    Day   Time    Queue"
    echo "  --------------------------  ----  ------  ----------------"

    for s in resp.slots.get:
        let
            dt        = if s.datetime.isSome: s.datetime.get else: ""
            day       = if s.dayOfWeek.isSome: dayName(s.dayOfWeek.get) else: ""
            time      = if s.time.isSome: s.time.get else: ""
            queueName = if s.queueName.isSome: s.queueName.get else: ""

        echo fmt"  {dt:<26}  {day:<4}  {time:<6}  {queueName}"


proc renderNextSlot(resp: late_queue.next_slot_resp) =
    if resp.nextSlot.isNone:
        echo "No available slot found."
        return

    echo fmt"Next Slot: {resp.nextSlot.get}"

    if resp.queueName.isSome:
        echo fmt"Queue    : {resp.queueName.get}"
    if resp.queueId.isSome:
        echo fmt"Queue ID : {resp.queueId.get}"
    if resp.timezone.isSome:
        echo fmt"Timezone : {resp.timezone.get}"


# --------------------------------------------
# Subcommands
# --------------------------------------------

proc runQueueList(args: seq[string], conf: GldConfig) =
    let apiKey = requireApiKey(conf)

    let
        rawMode   = hasFlag(args, "--raw")
        allMode   = hasFlag(args, "--all")
        queueIdOv = pickArg(args, "--id")
        profileOv = pickArg(args, "--profile")

    let profileId =
        if profileOv.isSome: profileOv.get
        elif conf.profileId.isSome: conf.profileId.get
        else:
            raise newException(ValueError, "No profile ID. Run: gld init or use --profile")

    if rawMode:
        let raw = waitFor late_queue.getQueueSlotsRaw(
            api_key    = apiKey
            ,profileId = profileId
            ,queueId   = queueIdOv
            ,all       = allMode
        )
        echo raw
        return

    let res = waitFor late_queue.getQueueSlots(
        api_key    = apiKey
        ,profileId = profileId
        ,queueId   = queueIdOv
        ,all       = allMode
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to get queue slots.")

    let resp = res.val

    # API returns:
    # - `queues` array when all=true
    # - `schedule` for single queue request
    if resp.queues.isSome and resp.queues.get.len > 0:
        renderQueues(resp.queues.get)
    elif resp.schedule.isSome:
        renderQueue(resp.schedule.get)
    else:
        echo "(no queue data returned)"
        echo "Hint: try --raw to see the actual API response"


proc runQueuePreview(args: seq[string], conf: GldConfig) =
    let apiKey = requireApiKey(conf)

    let
        rawMode   = hasFlag(args, "--raw")
        countOv   = pickArg(args, "--count")
        profileOv = pickArg(args, "--profile")

    let profileId =
        if profileOv.isSome: profileOv.get
        elif conf.profileId.isSome: conf.profileId.get
        else:
            raise newException(ValueError, "No profile ID. Run: gld init or use --profile")

    var count = none int
    if countOv.isSome:
        try:
            count = some parseInt(countOv.get)
        except ValueError:
            raise newException(ValueError, "Invalid --count value: " & countOv.get)

    if rawMode:
        let raw = waitFor late_queue.previewQueueRaw(
            api_key    = apiKey
            ,profileId = profileId
            ,count     = count
        )
        echo raw
        return

    let res = waitFor late_queue.previewQueue(
        api_key    = apiKey
        ,profileId = profileId
        ,count     = count
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to preview queue.")

    renderPreview(res.val)


proc runQueueNext(args: seq[string], conf: GldConfig) =
    let apiKey = requireApiKey(conf)

    let
        rawMode   = hasFlag(args, "--raw")
        queueIdOv = pickArg(args, "--id")
        profileOv = pickArg(args, "--profile")

    let profileId =
        if profileOv.isSome: profileOv.get
        elif conf.profileId.isSome: conf.profileId.get
        else:
            raise newException(ValueError, "No profile ID. Run: gld init or use --profile")

    if rawMode:
        let raw = waitFor late_queue.nextSlotRaw(
            api_key    = apiKey
            ,profileId = profileId
            ,queueId   = queueIdOv
        )
        echo raw
        return

    let res = waitFor late_queue.nextSlot(
        api_key    = apiKey
        ,profileId = profileId
        ,queueId   = queueIdOv
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to get next slot.")

    renderNextSlot(res.val)


proc runQueueDelete(args: seq[string], conf: GldConfig) =
    let apiKey = requireApiKey(conf)

    let
        rawMode   = hasFlag(args, "--raw")
        queueIdOv = pickArg(args, "--id")
        profileOv = pickArg(args, "--profile")

    let profileId =
        if profileOv.isSome: profileOv.get
        elif conf.profileId.isSome: conf.profileId.get
        else:
            raise newException(ValueError, "No profile ID. Run: gld init or use --profile")

    if queueIdOv.isNone:
        raise newException(ValueError, "Missing --id <queueId>. Specify which queue to delete.")

    let queueId = queueIdOv.get

    if rawMode:
        let raw = waitFor late_queue.deleteQueueRaw(
            api_key    = apiKey
            ,profileId = profileId
            ,queueId   = queueId
        )
        echo raw
        return

    let res = waitFor late_queue.deleteQueue(
        api_key    = apiKey
        ,profileId = profileId
        ,queueId   = queueId
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to delete queue.")

    echo "✅ " & res.val.message


proc runQueueCreate(args: seq[string], conf: GldConfig) =
    ## Interactive queue creation
    ## For now, a simple non-interactive version with flags
    let apiKey = requireApiKey(conf)

    let
        rawMode     = hasFlag(args, "--raw")
        profileOv   = pickArg(args, "--profile")
        nameOv      = pickArg(args, "--name")
        timezoneOv  = pickArg(args, "--timezone")
        activeOv    = hasFlag(args, "--active")
        inactiveOv  = hasFlag(args, "--inactive")

    let profileId =
        if profileOv.isSome: profileOv.get
        elif conf.profileId.isSome: conf.profileId.get
        else:
            raise newException(ValueError, "No profile ID. Run: gld init or use --profile")

    if nameOv.isNone:
        raise newException(ValueError, "Missing --name <queue_name>")

    if timezoneOv.isNone:
        raise newException(ValueError, "Missing --timezone <tz> (e.g., America/New_York)")

    # Parse slots from --slot flags: --slot "1:09:00" --slot "3:18:30"
    # Format: "dayOfWeek:HH:MM"
    var slots: seq[late_queue.queue_slot] = @[]
    for i, a in args:
        if a == "--slot" and i + 1 < args.len:
            let parts = args[i + 1].split(":")
            if parts.len >= 2:
                let day = parseInt(parts[0])
                let time = parts[1 .. ^1].join(":")
                slots.add late_queue.qSlot(day, time)

    if slots.len == 0:
        raise newException(ValueError, "No slots specified. Use --slot \"<day>:<HH:MM>\" (e.g., --slot \"1:09:00\")")

    var active = none bool
    if activeOv:
        active = some true
    elif inactiveOv:
        active = some false

    if rawMode:
        let raw = waitFor late_queue.createQueueRaw(
            api_key    = apiKey
            ,profileId = profileId
            ,name      = nameOv.get
            ,timezone  = timezoneOv.get
            ,slots     = slots
            ,active    = active
        )
        echo raw
        return

    let res = waitFor late_queue.createQueue(
        api_key    = apiKey
        ,profileId = profileId
        ,name      = nameOv.get
        ,timezone  = timezoneOv.get
        ,slots     = slots
        ,active    = active
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to create queue.")

    if res.val.message.isSome:
        echo "✅ " & res.val.message.get

    if res.val.queue.isSome:
        echo ""
        renderQueue(res.val.queue.get)


proc runQueueUpdate(args: seq[string], conf: GldConfig) =
    let apiKey = requireApiKey(conf)

    let
        rawMode        = hasFlag(args, "--raw")
        profileOv      = pickArg(args, "--profile")
        queueIdOv      = pickArg(args, "--id")
        nameOv         = pickArg(args, "--name")
        timezoneOv     = pickArg(args, "--timezone")
        activeOv       = hasFlag(args, "--active")
        inactiveOv     = hasFlag(args, "--inactive")
        setDefaultOv   = hasFlag(args, "--default")
        reshuffleOv    = hasFlag(args, "--reshuffle")

    let profileId =
        if profileOv.isSome: profileOv.get
        elif conf.profileId.isSome: conf.profileId.get
        else:
            raise newException(ValueError, "No profile ID. Run: gld init or use --profile")

    if timezoneOv.isNone:
        raise newException(ValueError, "Missing --timezone <tz>")

    # Parse slots
    var slots: seq[late_queue.queue_slot] = @[]
    for i, a in args:
        if a == "--slot" and i + 1 < args.len:
            let parts = args[i + 1].split(":")
            if parts.len >= 2:
                let day = parseInt(parts[0])
                let time = parts[1 .. ^1].join(":")
                slots.add late_queue.qSlot(day, time)

    if slots.len == 0:
        raise newException(ValueError, "No slots specified. Use --slot \"<day>:<HH:MM>\"")

    var active = none bool
    if activeOv:
        active = some true
    elif inactiveOv:
        active = some false

    var setAsDefault = none bool
    if setDefaultOv:
        setAsDefault = some true

    var reshuffleExisting = none bool
    if reshuffleOv:
        reshuffleExisting = some true

    if rawMode:
        let raw = waitFor late_queue.updateQueueRaw(
            api_key           = apiKey
            ,profileId        = profileId
            ,timezone         = timezoneOv.get
            ,slots            = slots
            ,queueId          = queueIdOv
            ,name             = nameOv
            ,active           = active
            ,setAsDefault     = setAsDefault
            ,reshuffleExisting = reshuffleExisting
        )
        echo raw
        return

    let res = waitFor late_queue.updateQueue(
        api_key           = apiKey
        ,profileId        = profileId
        ,timezone         = timezoneOv.get
        ,slots            = slots
        ,queueId          = queueIdOv
        ,name             = nameOv
        ,active           = active
        ,setAsDefault     = setAsDefault
        ,reshuffleExisting = reshuffleExisting
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to update queue.")

    if res.val.message.isSome:
        echo "✅ " & res.val.message.get

    if res.val.queue.isSome:
        echo ""
        renderQueue(res.val.queue.get)


# --------------------------------------------
# Main entry point
# --------------------------------------------

proc runQueue*(args: seq[string]) =
    let conf = loadConfig()

    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        printQueueHelp()
        return

    # Determine subcommand
    var subCmd = ""
    var subArgs: seq[string] = @[]

    for i, a in args:
        if not a.startsWith("-"):
            subCmd = a.toLowerAscii
            subArgs = args[i + 1 .. ^1]
            break

    # Also pass through flags that appear before subcommand
    for i, a in args:
        if a.startsWith("-"):
            subArgs.add a
            if a in ["--profile", "--id", "--count", "--name", "--timezone", "--slot"] and i + 1 < args.len:
                subArgs.add args[i + 1]
        else:
            break

    case subCmd
    of "":
        # Default: list queue(s)
        runQueueList(args, conf)
    of "list", "ls":
        runQueueList(subArgs, conf)
    of "preview":
        runQueuePreview(subArgs, conf)
    of "next", "next-slot":
        runQueueNext(subArgs, conf)
    of "delete", "rm", "remove":
        runQueueDelete(subArgs, conf)
    of "create", "new", "add":
        runQueueCreate(subArgs, conf)
    of "update", "set", "edit":
        runQueueUpdate(subArgs, conf)
    else:
        echo fmt"Unknown subcommand: {subCmd}"
        echo ""
        printQueueHelp()