import
    std / [
        os
        ,strformat
        ,strutils
        ,options
        ,asyncdispatch
        ,mimetypes
        ,sequtils
        ,times
    ]

import
    ic
    ,rz
    ,termui

import
    ../../lately / [
        profiles
        ,media
        ,posts
    ]

import
    types
    ,paths
    ,./store_config
    ,./store_uploads
    # ,./cmd_agent  # Temporarily disabled due to llmm version mismatch
    # ,cmd_accts
    # ,cmd_queue




# --------------------------------------------
# Helpers
# --------------------------------------------

proc humanBytes(n: int) : string =
    if n < 1024: return &"{n} B"
    if n < 1024 * 1024: return &"{(n.float / 1024.0):.1f} KB"
    if n < 1024 * 1024 * 1024: return &"{(n.float / (1024.0 * 1024.0)):.1f} MB"
    return &"{(n.float / (1024.0 * 1024.0 * 1024.0)):.1f} GB"


proc guessContentType(filePath: string) : string =
    let sp = splitFile(filePath)
    var mt = newMimetypes()
    let ext = if sp.ext.startsWith("."): sp.ext[1 .. ^1] else: sp.ext
    result = mt.getMimetype(ext, default = "application/octet-stream")


proc mustHaveFile(path: string) =
    if path.strip.len == 0:
        raise newException(ValueError, "Missing file path.")
    if not fileExists(path):
        raise newException(ValueError, "File not found: " & path)


# --------------------------------------------
# gld init
# --------------------------------------------

proc runInit*() =
    var conf = loadConfig()

    termuiLabel("Config location", configPath())
    let apiKey = termuiAsk("Late API Key (Bearer token)", defaultValue = conf.apiKey)

    if apiKey.strip.len == 0:
        echo "Cancelled (no API key)."
        return

    conf.apiKey = apiKey.strip

    # Test by listing profiles
    let profRes = waitFor listProfiles(conf.apiKey, includeOverLimit = true)
    profRes.isErr:
        icr profRes.err
        raise newException(ValueError, "API key test failed. Check your key and try again.")

    let profs = profRes.val.profiles

    if profs.len == 0:
        echo "No profiles found. Let's create one."
        let name = termuiAsk("Profile name", defaultValue = "My Profile")
        let desc = termuiAsk("Profile description (optional)", defaultValue = "")
        let color = termuiAsk("Profile color hex (optional)", defaultValue = "#4CAF50")

        let createRes = waitFor createProfile(
            api_key      = conf.apiKey
            ,name        = name
            ,description = (if desc.strip.len == 0: none string else: some desc.strip)
            ,color       = (if color.strip.len == 0: none string else: some color.strip)
        )

        createRes.isErr:
            icr createRes.err
            raise newException(ValueError, "Failed to create profile.")

        conf.profileId = some createRes.val.profile.id
        saveConfig(conf)

        echo "✅ Initialized."
        echo "Default profileId: " & conf.profileId.get
        return

    let
        createLabel = "➕ Create New Profile"
        options     = profs.mapIt(
            (if it.isDefault: "* " else: "  ") & it.name & "  (" & it.id & ")"
        )

    let picked = termuiSelect(
        "Select a default profile (or choose Create New)"
        ,options = options & @[createLabel]
    )

    if picked == createLabel:
        let name  = termuiAsk("Profile name", defaultValue = "My Profile")
        let desc  = termuiAsk("Profile description (optional)", defaultValue = "")
        let color = termuiAsk("Profile color hex (optional)", defaultValue = "#4CAF50")

        let createRes = waitFor createProfile(
            api_key      = conf.apiKey
            ,name        = name
            ,description = (if desc.strip.len == 0: none string else: some desc.strip)
            ,color       = (if color.strip.len == 0: none string else: some color.strip)
        )

        createRes.isErr:
            icr createRes.err
            raise newException(ValueError, "Failed to create profile.")

        conf.profileId = some createRes.val.profile.id
    else:
        # picked string looks like: "* Name  (id)" or "  Name  (id)"
        var chosenId = ""
        for p in profs:
            if picked.contains("(" & p.id & ")"):
                chosenId = p.id
                break

        if chosenId.len == 0:
            raise newException(ValueError, "Could not determine selected profile id from selection.")
        conf.profileId = some chosenId

    saveConfig(conf)

    echo "✅ Initialized."
    echo "Default profileId: " & conf.profileId.get
    echo "Config: " & configPath()

    # Optional: Agent setup
    echo ""
    echo "🤖 Would you like to configure the AI Agent?"
    echo "   The agent lets you use natural language to manage your social media."
    echo "   Example: 'gld agent \"post a thread about AI to Twitter\"'"
    echo ""

    # Agent temporarily disabled due to llmm version mismatch
    echo ""
    echo "Agent setup temporarily disabled. You can configure it later."



# --------------------------------------------
# gld profiles
# --------------------------------------------

proc runProfiles*(args: seq[string]) =
    let conf = loadConfig()
    let apiKey = requireApiKey(conf)

    let includeOver = args.anyIt(it == "--all" or it == "--includeOverLimit")
    let res = waitFor listProfiles(apiKey, includeOverLimit = includeOver)

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to list profiles.")

    for p in res.val.profiles:
        let defMark = if p.isDefault: "*" else: " "
        let overMark = if p.isOverLimit.isSome and p.isOverLimit.get: " (over-limit)" else: ""
        echo &"{defMark} {p.name}  id={p.id}{overMark}"


# --------------------------------------------
# gld uploads (list cache)
# --------------------------------------------

proc runUploads*(args: seq[string]) =
    discard args
    var uf = loadUploads()
    uf.sortUploadsNewestish()

    if uf.uploads.len == 0:
        echo "No cached uploads yet."
        echo "Try: gld upload <file_path>"
        return

    for u in uf.uploads:
        let s = if u.size.isSome: humanBytes(u.size.get) else: "?"
        echo &"- {u.filename}  {u.contentType}  {s}"
        echo &"  publicUrl: {u.publicUrl}"


# --------------------------------------------
# gld upload <file>
# --------------------------------------------

proc runUpload*(args: seq[string]) =
    if args.len == 0:
        raise newException(ValueError, "Usage: gld upload <file_path>")

    let filePath = args[0]
    mustHaveFile(filePath)

    let conf = loadConfig()
    let apiKey = requireApiKey(conf)

    let fname = splitFile(filePath).name & splitFile(filePath).ext
    let cType = guessContentType(filePath)

    let fsize = getFileSize(filePath).int

    # Step 1: presign -> uploadUrl + publicUrl
    let pres = waitFor mediaPresign(
        api_key      = apiKey
        ,filename    = fname
        ,contentType = cType
        ,size        = some fsize
    )

    pres.isErr:
        icr pres.err
        raise newException(ValueError, "Failed to presign upload.")

    # Step 2: PUT bytes to uploadUrl
    let putRes = waitFor mediaUploadToPresignedUrl(
        uploadUrl    = pres.val.uploadUrl
        ,file_path   = filePath
        ,contentType = cType
    )

    putRes.isErr:
        icr putRes.err
        raise newException(ValueError, "Upload (PUT) failed.")

    var uf = loadUploads()

    let u = Upload(
        filename    : fname
        ,contentType : cType
        ,size        : some fsize
        ,uploadUrl   : pres.val.uploadUrl
        ,publicUrl   : pres.val.publicUrl
    )

    uf.addOrUpdateUpload(u)
    saveUploads(uf)

    echo "✅ Uploaded"
    echo "publicUrl: " & pres.val.publicUrl


# --------------------------------------------
# gld sched (scheduled posts)
# --------------------------------------------

proc runSched*(args: seq[string]) =
    let conf = loadConfig()
    let apiKey = requireApiKey(conf)

    var
        profileId = ""
        limit     = 25

    # very small flag parse
    for i in 0 ..< args.len:
        if args[i] == "--profile" and i + 1 < args.len:
            profileId = args[i + 1]
        if args[i] == "--limit" and i + 1 < args.len:
            if args[i + 1].parseInt > 0:
                limit = args[i + 1].parseInt

    if profileId.strip.len == 0 and conf.profileId.isSome:
        profileId = conf.profileId.get

    let res = waitFor listPosts(
        api_key      = apiKey
        ,page        = 1
        ,limit       = limit
        ,status      = "scheduled"
        ,profileId   = profileId
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to list scheduled posts.")

    let posts = res.val.posts
    if posts.len == 0:
        echo "No scheduled posts."
        return

    for p in posts:
        # Parse UTC time and convert to local timezone in 12-hour format
        let whenStr = if p.scheduledFor.isSome:
            let utcTime = parse(p.scheduledFor.get, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc())
            let localTime = utcTime.local()
            localTime.format("MMM d, yyyy h:mm:ss tt")
        else:
            "(no scheduledFor)"
        let title = if p.title.isSome and p.title.get.len > 0: p.title.get else: ""
        
        if title.len > 0:
            echo &"- {p.id}  {whenStr}"
            echo &"  title: {title}"
        else:
            echo &"- {p.id}  {whenStr}"

        if p.platforms.isSome and p.platforms.get.len > 0:
            let plats = p.platforms.get.mapIt(it.platform).join(", ")
            echo &"  platforms: {plats}"
        if p.status.isSome:
            echo &"  status: {p.status.get}"


discard """
This module depends on:
- termui
- lately SDK package
Compile:
nim c -d:ssl -d:release -r src/gld.nim
"""
