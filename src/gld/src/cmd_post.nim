# src/gld/cmd_post.nim
##
## Intuitive posting API for GLD CLI
##
## Usage patterns:
##   gld post "my text"                    # Interactive platform selection
##   gld post "my text" --to x,threads     # Direct to specific platforms
##   gld post "my text" --prof finsta      # Post using 'finsta' profile
##   gld x "my text"                       # Shorthand for X/Twitter
##   gld threads "my text"                 # Shorthand for Threads
##   gld ig "my text" --file photo.jpg     # Instagram with media
##   gld linkedin "my text"                # LinkedIn post
##   gld post --file video.mp4            # Media-first flow

import
    std/[
        strformat
        ,strutils
        ,sequtils
        ,options
        ,asyncdispatch
        ,os
        ,mimetypes
        ,tables
        ,json
    ]

import
    ic
    ,rz
    ,termui

import
     ../../lately/posts as late_posts
    ,../../lately/media as late_media
    ,../../lately/accounts as late_accounts
    ,../../lately/profiles as late_profiles
    ,../../lately/queue as late_queue
    ,../../lately/models
    ,store_config
    ,store_uploads
    ,types


# --------------------------------------------
# Platform aliases and mappings
# --------------------------------------------

const
    PlatformAliases* = {
        # X / Twitter
        "x": "twitter"
        ,"twitter": "twitter"
        ,"tw": "twitter"

        # Threads
        ,"threads": "threads"
        ,"th": "threads"

        # Instagram
        ,"instagram": "instagram"
        ,"ig": "instagram"
        ,"insta": "instagram"

        # LinkedIn
        ,"linkedin": "linkedin"
        ,"li": "linkedin"

        # Facebook
        ,"facebook": "facebook"
        ,"fb": "facebook"

        # TikTok
        ,"tiktok": "tiktok"
        ,"tt": "tiktok"

        # YouTube
        ,"youtube": "youtube"
        ,"yt": "youtube"

        # Pinterest
        ,"pinterest": "pinterest"
        ,"pin": "pinterest"

        # Bluesky
        ,"bluesky": "bluesky"
        ,"bsky": "bluesky"
    }.toTable

    PlatformDisplayNames* = {
        "twitter": "X (Twitter)"
        ,"threads": "Threads"
        ,"instagram": "Instagram"
        ,"linkedin": "LinkedIn"
        ,"facebook": "Facebook"
        ,"tiktok": "TikTok"
        ,"youtube": "YouTube"
        ,"pinterest": "Pinterest"
        ,"bluesky": "Bluesky"
    }.toTable

    PlatformCharLimits* = {
        "twitter": 280
        ,"threads": 500
        ,"instagram": 2200
        ,"linkedin": 3000
        ,"facebook": 63206
        ,"tiktok": 2200
        ,"bluesky": 300
    }.toTable


type
    PostParams          * = object
        text            * : Option[string]
        platforms       * : seq[string]       # normalized platform names
        mediaFiles      * : seq[string]       # file paths
        scheduledFor    * : Option[string]
        isDraft         * : bool
        useQueue        * : bool
        title           * : Option[string]
        tags            * : seq[string]
        hashtags        * : seq[string]
        rawMode         * : bool
        dryRun          * : bool
        # LinkedIn-specific
        linkedInOrgUrn  * : Option[string]    # urn:li:organization:123456
        linkedInDocTitle* : Option[string]    # For document/PDF posts
        disableLinkPreview* : Option[bool]    # Suppress URL preview
        firstComment    * : Option[string]    # Auto-post first comment

    PostMode* = enum
        pmPublishNow
        pmQueue
        pmSchedule
        pmDraft


# --------------------------------------------
# Arg parsing helpers
# --------------------------------------------


proc tryPrintNextQueueSlot*(
    apiKey: string
    ,profileId: Option[string]
) =
    if profileId.isNone:
        return

    let res = waitFor late_queue.nextSlot(
        api_key    = apiKey
        ,profileId = profileId.get
        ,queueId   = none string
    )

    res.isErr:
        return

    if res.val.nextSlot.isSome:
        echo "   Next slot: " & res.val.nextSlot.get
        if res.val.queueName.isSome and res.val.timezone.isSome:
            echo &"   Queue: {res.val.queueName.get}  ({res.val.timezone.get})"


proc promptForText(platformHint: string = ""): string =
    ## Prompts user for post text with optional platform hint
    let prompt =
        if platformHint.len > 0:
            &"Post text for {platformHint}:"
        else:
            "Post text:"

    result = termuiAsk(prompt)



proc pickArg(
    args                : seq[string]
    ,key                : string
)                       : Option[string] =
    ## Supports:
    ##   --to=twitter,tiktok
    ##   --to twitter,tiktok
    ##   --to twitter, tiktok
    ##   --to twitter, tiktok, instagram
    for i, a in args:
        if a.startsWith(key & "="):
            return some a.split("=", 1)[1].strip

        if a == key and i + 1 < args.len:
            var parts: seq[string]

            var j = i + 1
            while j < args.len:
                let t = args[j]

                # stop at next flag
                if t.startsWith("--") or (t.startsWith("-") and t.len > 1):
                    break

                parts.add t
                inc j

            if parts.len == 0:
                return none string

            # join with spaces so "twitter, tiktok" becomes "twitter, tiktok"
            return some parts.join(" ").strip

    return none string


proc pickArgMulti(
    args                : seq[string]
    ,key                : string
)                       : seq[string] =
    ## Collects all values for a repeated flag (e.g., --file a --file b)
    for i, a in args:
        if a.startsWith(key & "="):
            result.add a.split("=", 1)[1]
        elif a == key and i + 1 < args.len:
            result.add args[i + 1]


proc hasFlag(
    args                : seq[string]
    ,key                : string
)                       : bool =
    result = args.anyIt(it == key)


proc getPositionalText(args: seq[string]): Option[string] =
    ## Gets the first non-flag argument as the post text
    for a in args:
        if not a.startsWith("-") and not a.startsWith("--"):
            return some a
    return none string


proc normalizePlatform(input: string): Option[string] =
    let lower = input.toLowerAscii.strip
    if PlatformAliases.hasKey(lower):
        return some PlatformAliases[lower]
    return none string


proc parsePlatformList(raw: string): seq[string] =
    var s = raw
    s = s.replace(" ,", ",")
    s = s.replace(", ", ",")
    for part in s.split(","):
        let norm = normalizePlatform(part.strip)
        if norm.isSome:
            result.add norm.get


proc stripOuterQuotes(s: string): string =
    result = s.strip
    if result.len >= 2:
        let a = result[0]
        let b = result[^1]
        if (a == '"' and b == '"') or (a == '\'' and b == '\''):
            result = result[1 .. ^2].strip


proc parseUserFileList*(input: string): seq[string] =
    ## Accepts:
    ##   C:\a\b.png
    ##   "C:\a\b has spaces.png"
    ##   C:\a.png, C:\b.mp4
    ##   C:\a.png, "C:\b has spaces.mp4"
    var s = input.strip
    if s.len == 0:
        return @[]

    # Normalize comma spacing a bit
    s = s.replace(" ,", ",")
    s = s.replace(", ", ",")

    for part in s.split(","):
        let p = stripOuterQuotes(part)
        if p.len > 0:
            result.add p


proc platformRequiresMedia(platform: string): bool =
    ## Based on API behavior: Instagram requires media. (You can extend later.)
    platform == "instagram"


proc ensureTextInteractive(
    postText             : var Option[string]
    ,platformHint        : string = ""
) : bool =
    ## Ensures postText isSome (can still be blank if user enters blank; caller can decide).
    if postText.isNone:
        postText = some promptForText(platformHint)
    return postText.isSome


proc ensureMediaInteractive*(
    platforms            : seq[string]
    ,mediaFiles          : var seq[string]
) : bool =
    ## If any selected platform requires media and none was provided, prompt for it.
    if mediaFiles.len > 0:
        return true

    var needsMedia = false
    for p in platforms:
        if platformRequiresMedia(p):
            needsMedia = true
            break

    if not needsMedia:
        return true

    echo ""
    echo "📎 Media required"
    echo "Instagram posts require media (image/video)."
    echo ""

    let ans = termuiAsk("Path to image/video (comma-separated if multiple):").strip
    let picked = parseUserFileList(ans)

    if picked.len == 0:
        echo "No media provided. Aborting."
        return false

    for f in picked:
        if not fileExists(f):
            raise newException(ValueError, "File not found: " & f)

    mediaFiles = picked
    return true


# --------------------------------------------
# Profile resolution
# --------------------------------------------

proc resolveProfileId*(
    apiKey: string
    ,profileArg: Option[string]
    ,configProfileId: Option[string]
): Future[Rz[Option[string]]] {.async.} =
    ## Resolves a profile argument to a profile ID.
    ## - If profileArg looks like an ID (starts with certain patterns or is long), use it directly
    ## - Otherwise, treat it as a name and look it up
    ## - Falls back to configProfileId if no profileArg provided
    
    if profileArg.isNone:
        return ok configProfileId
    
    let arg = profileArg.get.strip
    
    if arg.len == 0:
        return ok configProfileId
    
    # Heuristic: if it looks like an ID (24+ hex chars, or contains only hex-like chars and is long)
    # treat it as an ID directly. Otherwise, look up by name.
    let looksLikeId = arg.len >= 20 and arg.allIt(it in {'a'..'f', 'A'..'F', '0'..'9', '-', '_'})
    
    if looksLikeId:
        return ok some(arg)
    
    # Look up by name
    let profilesRes = await late_profiles.listProfiles(api_key = apiKey)
    
    profilesRes.isErr:
        return err[Option[string]]("Failed to fetch profiles: " & profilesRes.err)
    
    # Case-insensitive match on name
    let argLower = arg.toLowerAscii
    for p in profilesRes.val.profiles:
        if p.name.toLowerAscii == argLower:
            return ok some(p.id)
    
    # No match found - show available profiles
    var availableNames: seq[string]
    for p in profilesRes.val.profiles:
        availableNames.add p.name
    
    let msg = &"Profile '{arg}' not found. Available profiles: {availableNames.join(\", \")}"
    return err[Option[string]](msg)


proc resolveProfileIdSync*(
    apiKey: string
    ,profileArg: Option[string]
    ,configProfileId: Option[string]
): Rz[Option[string]] =
    ## Synchronous wrapper for resolveProfileId
    waitFor resolveProfileId(apiKey, profileArg, configProfileId)


# --------------------------------------------
# Media helpers
# --------------------------------------------

proc guessContentType(filePath: string): string =
    let sp = splitFile(filePath)
    var mt = newMimetypes()
    let ext = if sp.ext.startsWith("."): sp.ext[1 .. ^1] else: sp.ext
    result = mt.getMimetype(ext, default = "application/octet-stream")


proc isImageFile(contentType: string): bool =
    contentType.startsWith("image/")


proc isVideoFile(contentType: string): bool =
    contentType.startsWith("video/")


proc humanBytes(n: int): string =
    if n < 1024: return &"{n} B"
    if n < 1024 * 1024: return &"{(n.float / 1024.0):.1f} KB"
    if n < 1024 * 1024 * 1024: return &"{(n.float / (1024.0 * 1024.0)):.1f} MB"
    return &"{(n.float / (1024.0 * 1024.0 * 1024.0)):.1f} GB"


proc uploadMediaFile(
    apiKey: string
    ,filePath: string
): Future[Rz[string]] {.async.} =
    ## Uploads a file and returns the publicUrl
    if not fileExists(filePath):
        return err[string]("File not found: " & filePath)

    let
        fname = splitFile(filePath).name & splitFile(filePath).ext
        cType = guessContentType(filePath)
        fsize = getFileSize(filePath).int

    # Presign
    let pres = await late_media.mediaPresign(
        api_key      = apiKey
        ,filename    = fname
        ,contentType = cType
        ,size        = some fsize
    )

    pres.isErr:
        return err[string]("Presign failed: " & pres.err)

    # Upload
    let putRes = await late_media.mediaUploadToPresignedUrl(
        uploadUrl    = pres.val.uploadUrl
        ,file_path   = filePath
        ,contentType = cType
    )

    putRes.isErr:
        return err[string]("Upload failed: " & putRes.err)

    return ok pres.val.publicUrl


# --------------------------------------------
# Account/Platform discovery
# --------------------------------------------

proc getConnectedPlatforms*(
    apiKey: string
    ,profileId: Option[string]
): Future[Rz[seq[tuple[platform: string, accountId: string, username: string]]]] {.async.} =
    ## Fetches connected accounts and returns available platforms
    let res = await late_accounts.listAccounts(
        api_key    = apiKey
        ,profileId = profileId
    )

    res.isErr:
        return err[seq[tuple[platform: string, accountId: string, username: string]]](res.err)

    var platforms: seq[tuple[platform: string, accountId: string, username: string]]

    for acct in res.val.accounts:
        if acct.isActive.isSome and acct.isActive.get:
            let username = if acct.username.isSome: acct.username.get else: ""
            platforms.add (platform: $acct.platform, accountId: acct.id, username: username)

    return ok platforms


# --------------------------------------------
# Help
# --------------------------------------------

proc printPostHelp*() =
    echo "gld post - Create and publish social media posts"
    echo ""
    echo "Usage:"
    echo "  gld post \"your text here\"              Interactive platform selection"
    echo "  gld post \"text\" --to x,threads         Post to specific platforms"
    echo "  gld post \"text\" --prof finsta          Post using 'finsta' profile"
    echo "  gld post --file image.jpg              Media-first (prompts for text)"
    echo ""
    echo "Platform Shortcuts:"
    echo "  gld x \"text\"                           Post to X (Twitter)"
    echo "  gld threads \"text\"                     Post to Threads"
    echo "  gld ig \"text\" --file photo.jpg         Post to Instagram"
    echo "  gld linkedin \"text\"                    Post to LinkedIn"
    echo "  gld fb \"text\"                          Post to Facebook"
    echo "  gld tiktok --file video.mp4            Post to TikTok"
    echo "  gld bluesky \"text\"                     Post to Bluesky"
    echo ""
    echo "Options:"
    echo "  --to <platforms>      Comma-separated platforms (x,threads,linkedin)"
    echo "  --prof <name|id>      Profile name or ID to post from"
    echo "  --profile <name|id>   Alias for --prof"
    echo "  --file <path>         Attach media file (can use multiple times)"
    echo "  --schedule <time>     Schedule for later (ISO 8601 or natural)"
    echo "  --draft               Save as draft instead of publishing"
    echo "  --queue               Add to posting queue"
    echo "  --title <title>       Post title (for platforms that support it)"
    echo "  --tags <t1,t2>        Add tags"
    echo "  --hashtags <h1,h2>    Add hashtags"
    echo "  --first-comment <txt> Auto-post first comment (best for links)"
    echo "  --no-link-preview     Suppress URL preview card"
    echo "  --raw                 Print raw API response"
    echo "  --dry-run             Preview without posting"
    echo "  -h, --help            Show this help"
    echo ""
    echo "Examples:"
    echo ""
    echo "LinkedIn Options:"
    echo "  --linkedin-org <urn>  Post to company page (e.g., urn:li:organization:123456)"
    echo "  --linkedin-doc-title <title>  Title for PDF/carousel posts"
    echo "  gld x \"Just shipped a new feature! 🚀\""
    echo "  gld post \"Big announcement\" --to x,linkedin,threads"
    echo "  gld post \"Draft idea\" --draft --prof finsta"
    echo "  gld ig --file photo.jpg --text \"Check this out!\" --prof finsta"
    echo "  gld post \"Scheduled post\" --schedule \"2024-12-25T10:00:00Z\""
    echo "  gld linkedin \"Report\" --file report.pdf --linkedin-doc-title \"2024 Report\""
    echo "  gld linkedin \"Link in first comment\" --first-comment \"https://example.com\""
    echo ""


# --------------------------------------------
# Interactive flows
# --------------------------------------------


proc getPostMode*(params: PostParams): PostMode =
    if params.isDraft:
        return pmDraft
    if params.scheduledFor.isSome:
        return pmSchedule
    if params.useQueue:
        return pmQueue
    return pmPublishNow


proc modeLabel(mode: PostMode): string =
    case mode
    of pmDraft: "Draft"
    of pmSchedule: "Scheduled"
    of pmQueue: "Queue"
    of pmPublishNow: "Publish now"


proc confirmVerb(mode: PostMode): string =
    case mode
    of pmDraft: "save draft"
    of pmSchedule: "schedule"
    of pmQueue: "queue"
    of pmPublishNow: "publish"

proc selectPlatformsInteractive*(
    available: seq[tuple[platform: string, accountId: string, username: string]]
): seq[tuple[platform: string, accountId: string]] =
    ## Interactive multi-select for platforms
    if available.len == 0:
        echo "❌ No connected accounts found."
        echo "Connect accounts at: https://getlate.dev"
        return @[]

    var options: seq[string]
    for p in available:
        let display = PlatformDisplayNames.getOrDefault(p.platform, p.platform)
        let userStr = if p.username.len > 0: " (@" & p.username & ")" else: ""
        options.add display & userStr

    let selected = termuiSelectMultiple("Select platforms to post to:", options)

    for sel in selected:
        for i, opt in options:
            if sel == opt:
                result.add (platform: available[i].platform, accountId: available[i].accountId)
                break

proc confirmPost*(
    text: string
    ,platforms: seq[string]
    ,mediaFiles: seq[string]
    ,isDraft: bool
    ,scheduledFor: Option[string]
    ,useQueue: bool
    ,profileName: Option[string] = none string
): bool =
    var mode = pmPublishNow
    if isDraft:
        mode = pmDraft
    elif scheduledFor.isSome:
        mode = pmSchedule
    elif useQueue:
        mode = pmQueue

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📝 Post Preview"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if profileName.isSome:
        echo &"👤 Profile: {profileName.get}"

    if text.len > 0:
        echo ""
        let maxWidth = 60
        var remaining = text
        while remaining.len > maxWidth:
            let breakPoint = remaining[0..<maxWidth].rfind(' ')
            let bp = if breakPoint > 0: breakPoint else: maxWidth
            echo "  " & remaining[0..<bp]
            remaining = remaining[bp..^1].strip
        if remaining.len > 0:
            echo "  " & remaining
        echo ""

    echo &"📱 Platforms: {platforms.mapIt(PlatformDisplayNames.getOrDefault(it, it)).join(\", \")}"

    if mediaFiles.len > 0:
        echo &"📎 Media: {mediaFiles.len} file(s)"
        for f in mediaFiles:
            echo &"   - {splitFile(f).name}{splitFile(f).ext}"

    case mode
    of pmDraft:
        echo "📋 Mode: Draft"
    of pmSchedule:
        echo &"⏰ Mode: Scheduled ({scheduledFor.get})"
    of pmQueue:
        echo "🗂️  Mode: Queue (next available slot)"
    of pmPublishNow:
        echo "🚀 Mode: Publish now"

    for plat in platforms:
        if PlatformCharLimits.hasKey(plat):
            let limit = PlatformCharLimits[plat]
            if text.len > limit:
                echo &"⚠️  Warning: Text exceeds {plat} limit ({text.len}/{limit} chars)"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return termuiConfirm(&"Confirm {confirmVerb(mode)}?")

# --------------------------------------------
# Core posting logic
# --------------------------------------------




proc executePost*(
    apiKey: string
    ,profileId: Option[string]
    ,params: PostParams
    ,accountMap: Table[string, string]  # platform -> accountId
): Future[Rz[late_posts.post_write_resp]] {.async.} =
    ## Executes the actual post creation

    let mode = getPostMode(params)

    # Upload media files first
    var mediaItems: seq[mediaItem]

    if params.mediaFiles.len > 0:
        let spinner = termuiSpinner("Uploading media...")

        for filePath in params.mediaFiles:
            let uploadRes = await uploadMediaFile(apiKey, filePath)

            uploadRes.isErr:
                spinner.complete()
                return err[late_posts.post_write_resp](uploadRes.err)

            let cType = guessContentType(filePath)
            let mType =
                if isVideoFile(cType): mediaItemTypes.video
                elif isImageFile(cType): mediaItemTypes.image
                else: mediaItemTypes.image  # default

            mediaItems.add mediaItem(
                url      : uploadRes.val
                ,`type`  : mType
            )

        spinner.complete()
        echo &"✅ Uploaded {mediaItems.len} file(s)"

    # Build platform entries
    var platforms: seq[platform]
    for plat in params.platforms:
        if accountMap.hasKey(plat):
            # For LinkedIn, use the helper with platform-specific data
            if plat == "linkedin":
                platforms.add pLinkedIn(
                    accountId        = accountMap[plat]
                    ,firstComment    = params.firstComment
                    ,disableLinkPreview = params.disableLinkPreview
                    ,organizationUrn  = params.linkedInOrgUrn
                    ,documentTitle    = params.linkedInDocTitle
                )
            else:
                platforms.add platform(
                    platform  : plat
                    ,accountId: accountMap[plat]
                )

    if platforms.len == 0:
        return err[late_posts.post_write_resp]("No valid platform/account combinations found")

    # Determine publish mode flags for API
    var
        publishNow = none bool
        isDraft    = none bool

    if params.isDraft:
        isDraft = some true
    elif params.scheduledFor.isNone and not params.useQueue:
        publishNow = some true

    # Create the post
    let spinnerLabel =
        case mode
        of pmDraft:      "Saving draft..."
        of pmSchedule:   "Scheduling..."
        of pmQueue:      "Queueing..."
        of pmPublishNow: "Publishing..."

    let spinner = termuiSpinner(spinnerLabel)

    let res = await late_posts.createPost(
        api_key              = apiKey
        ,content             = params.text
        ,title               = params.title
        ,mediaItems          = mediaItems
        ,platforms           = platforms
        ,scheduledFor        = params.scheduledFor
        ,publishNow          = publishNow
        ,isDraft             = isDraft
        ,tags                = params.tags
        ,hashtags            = params.hashtags
        ,queuedFromProfile   = if params.useQueue and profileId.isSome: profileId else: none string
    )

    spinner.complete()
    return res

# --------------------------------------------
# Main entry points
# --------------------------------------------

proc runPost*(args: seq[string]) =
    ## Generic post command with interactive flow
    let conf = loadConfig()
    let apiKey = requireApiKey(conf)

    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        printPostHelp()
        return

    let
        rawMode      = hasFlag(args, "--raw")
        dryRun       = hasFlag(args, "--dry-run")
        isDraft      = hasFlag(args, "--draft")
        useQueue     = hasFlag(args, "--queue")
        toArg        = pickArg(args, "--to")
        scheduleArg  = pickArg(args, "--schedule")
        titleArg     = pickArg(args, "--title")
        tagsArg      = pickArg(args, "--tags")
        hashtagsArg  = pickArg(args, "--hashtags")
        fileArgs     = pickArgMulti(args, "--file")
        textArg      = pickArg(args, "--text")
        # LinkedIn-specific flags
        linkedInOrgArg = pickArg(args, "--linkedin-org")
        linkedInDocTitleArg = pickArg(args, "--linkedin-doc-title")
        disablePreviewArg = hasFlag(args, "--no-link-preview")
        firstCommentArg = pickArg(args, "--first-comment")

    # Support both --prof and --profile
    let profileArg =
        if pickArg(args, "--prof").isSome: pickArg(args, "--prof")
        elif pickArg(args, "--profile").isSome: pickArg(args, "--profile")
        else: none string

    # Resolve profile (name -> ID if needed)
    let profileRes = resolveProfileIdSync(apiKey, profileArg, conf.profileId)
    profileRes.isErr:
        echo &"❌ {profileRes.err}"
        return

    let profileId = profileRes.val

    # Get post text
    var postText = textArg
    if postText.isNone:
        postText = getPositionalText(args)

    # Fetch connected accounts
    let acctRes = waitFor getConnectedPlatforms(apiKey, profileId)
    acctRes.isErr:
        icr acctRes.err
        raise newException(ValueError, "Failed to fetch connected accounts")

    let available = acctRes.val

    if available.len == 0:
        echo "❌ No connected social accounts found."
        if profileArg.isSome:
            echo &"   (for profile: {profileArg.get})"
        echo "Connect accounts at: https://getlate.dev"
        return

    # Build account map
    var accountMap: Table[string, string]
    for a in available:
        accountMap[a.platform] = a.accountId

    # Determine platforms
    var selectedPlatforms: seq[tuple[platform: string, accountId: string]]

    if toArg.isSome:
        let requested = parsePlatformList(toArg.get)
        for plat in requested:
            if accountMap.hasKey(plat):
                selectedPlatforms.add (platform: plat, accountId: accountMap[plat])
            else:
                echo &"⚠️  Platform '{plat}' not connected, skipping"
    else:
        # Interactive selection
        selectedPlatforms = selectPlatformsInteractive(available)

    if selectedPlatforms.len == 0:
        echo "No platforms selected. Aborting."
        return

    # Prompt for text if not provided
    # If selected platforms require media, enforce it (interactive prompt if missing)
    var mediaFiles = fileArgs
    if not ensureMediaInteractive(
        platforms  = selectedPlatforms.mapIt(it.platform)
        ,mediaFiles = mediaFiles
    ):
        return

    # Always prompt for text if not provided (even if media exists)
    discard ensureTextInteractive(postText)

    if postText.isNone or postText.get.strip.len == 0:
        echo "No text provided. Aborting."
        return

    # Validate media files exist (covers CLI-provided --file too)
    for f in mediaFiles:
        if not fileExists(f):
            raise newException(ValueError, "File not found: " & f)


    if postText.isNone or postText.get.strip.len == 0:
        if fileArgs.len == 0:
            echo "No text or media provided. Aborting."
            return

    # Validate media files exist
    for f in fileArgs:
        if not fileExists(f):
            raise newException(ValueError, "File not found: " & f)

    let params = PostParams(
        text         : postText
        ,platforms   : selectedPlatforms.mapIt(it.platform)
        ,mediaFiles  : mediaFiles
        ,scheduledFor: scheduleArg
        ,isDraft     : isDraft
        ,useQueue    : useQueue
        ,title       : titleArg
        ,tags        : if tagsArg.isSome: tagsArg.get.split(",").mapIt(it.strip) else: @[]
        ,hashtags    : if hashtagsArg.isSome: hashtagsArg.get.split(",").mapIt(it.strip) else: @[]
        ,rawMode     : rawMode
        ,dryRun      : dryRun
        ,linkedInOrgUrn  : linkedInOrgArg
        ,linkedInDocTitle: linkedInDocTitleArg
        ,disableLinkPreview: some(disablePreviewArg)
        ,firstComment: firstCommentArg
    )

    # Confirm before posting
    if not dryRun:
        let confirmed = confirmPost(
            text         = params.text.get("")
            ,platforms   = params.platforms
            ,mediaFiles  = params.mediaFiles
            ,isDraft     = params.isDraft
            ,scheduledFor = params.scheduledFor
            ,useQueue    = params.useQueue
            ,profileName = profileArg
        )

        if not confirmed:
            echo "Cancelled."
            return

    if dryRun:
        echo "🔍 Dry run - would post to: " & params.platforms.join(", ")
        if profileArg.isSome:
            echo &"   Profile: {profileArg.get}"
        return

    # Execute
    var acctMapSimple: Table[string, string]
    for p in selectedPlatforms:
        acctMapSimple[p.platform] = p.accountId

    let res = waitFor executePost(
        apiKey      = apiKey
        ,profileId  = profileId
        ,params     = params
        ,accountMap = acctMapSimple
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to create post")

    if rawMode:
        # Would need jsony import for this
        echo "Post created successfully"
        echo "Post ID: " & res.val.post.id
    else:
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

        if res.val.message.isSome:
            echo "   " & res.val.message.get


proc runPlatformPost*(platform: string, args: seq[string]) =
    ## Shorthand for posting to a specific platform
    ## e.g., gld x "my post" -> runPlatformPost("x", @["my post"])

    let normalizedPlatform = normalizePlatform(platform)
    if normalizedPlatform.isNone:
        echo &"Unknown platform: {platform}"
        printPostHelp()
        return

    let plat = normalizedPlatform.get

    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        printPostHelp()
        return

    let
        conf   = loadConfig()
        apiKey = requireApiKey(conf)

    let
        rawMode      = hasFlag(args, "--raw")
        dryRun       = hasFlag(args, "--dry-run")
        isDraft      = hasFlag(args, "--draft")
        useQueue     = hasFlag(args, "--queue")
        scheduleArg  = pickArg(args, "--schedule")
        titleArg     = pickArg(args, "--title")
        tagsArg      = pickArg(args, "--tags")
        hashtagsArg  = pickArg(args, "--hashtags")
        fileArgs     = pickArgMulti(args, "--file")
        textArg      = pickArg(args, "--text")

    # Support both --prof and --profile
    let profileArg =
        if pickArg(args, "--prof").isSome: pickArg(args, "--prof")
        elif pickArg(args, "--profile").isSome: pickArg(args, "--profile")
        else: none string

    # Resolve profile (name -> ID if needed)
    let profileRes = resolveProfileIdSync(apiKey, profileArg, conf.profileId)
    profileRes.isErr:
        echo &"❌ {profileRes.err}"
        return

    let profileId = profileRes.val

    # Get post text
    var postText = textArg
    if postText.isNone:
        postText = getPositionalText(args)

    # Fetch accounts to get the accountId
    let acctRes = waitFor getConnectedPlatforms(apiKey, profileId)
    acctRes.isErr:
        icr acctRes.err
        raise newException(ValueError, "Failed to fetch connected accounts")

    # Find matching account
    var accountId = ""
    var username  = ""
    for a in acctRes.val:
        if a.platform == plat:
            accountId = a.accountId
            username  = a.username
            break

    let displayName = PlatformDisplayNames.getOrDefault(plat, plat)

    if accountId.len == 0:
        echo &"❌ No {displayName} account connected."
        if profileArg.isSome:
            echo &"   (for profile: {profileArg.get})"
        echo "Connect your account at: https://getlate.dev"
        return

    # Enforce media requirements for certain platforms (Instagram)
    var mediaFiles = fileArgs
    if not ensureMediaInteractive(
        platforms   = @[plat]
        ,mediaFiles = mediaFiles
    ):
        return

    # Always prompt for text if not provided (even if media exists)
    discard ensureTextInteractive(postText, displayName)

    if postText.isNone or postText.get.strip.len == 0:
        echo "No text provided. Aborting."
        return

    # Validate media files (final list that will be used)
    for f in mediaFiles:
        if not fileExists(f):
            raise newException(ValueError, "File not found: " & f)

    # Check character limit
    if postText.isSome and PlatformCharLimits.hasKey(plat):
        let
            limit   = PlatformCharLimits[plat]
            textLen = postText.get.len
        if textLen > limit:
            echo &"⚠️  Warning: Text ({textLen} chars) exceeds {displayName} limit ({limit})"
            if not termuiConfirm("Post anyway?"):
                echo "Cancelled."
                return

    let params = PostParams(
        text          : postText
        ,platforms    : @[plat]
        ,mediaFiles   : mediaFiles
        ,scheduledFor : scheduleArg
        ,isDraft      : isDraft
        ,useQueue     : useQueue
        ,title        : titleArg
        ,tags         : if tagsArg.isSome: tagsArg.get.split(",").mapIt(it.strip) else: @[]
        ,hashtags     : if hashtagsArg.isSome: hashtagsArg.get.split(",").mapIt(it.strip) else: @[]
        ,rawMode      : rawMode
        ,dryRun       : dryRun
    )

    let mode = getPostMode(params)

    # Quick confirm for single platform
    if not dryRun:
        let
            userStr = if username.len > 0: " (@" & username & ")" else: ""
            profStr = if profileArg.isSome: &" [{profileArg.get}]" else: ""
            head    =
                case mode
                of pmQueue:      "🗂️  Queueing for "
                of pmSchedule:   "⏰ Scheduling for "
                of pmDraft:      "📋 Saving draft for "
                of pmPublishNow: "📝 Posting to "

        echo ""
        echo &"{head}{displayName}{userStr}{profStr}"

        if postText.isSome:
            let preview =
                if postText.get.len > 50: postText.get[0..49] & "..." else: postText.get
            echo &"   \"{preview}\""

        if mediaFiles.len > 0:
            echo &"   📎 {mediaFiles.len} media file(s)"

        echo ""

        if not termuiConfirm(&"Confirm {confirmVerb(mode)}?"):
            echo "Cancelled."
            return

    if dryRun:
        echo &"🔍 Dry run - would {confirmVerb(mode)} to {displayName}"
        if profileArg.isSome:
            echo &"   Profile: {profileArg.get}"
        return

    var accountMap: Table[string, string]
    accountMap[plat] = accountId

    let res = waitFor executePost(
        apiKey      = apiKey
        ,profileId  = profileId
        ,params     = params
        ,accountMap = accountMap
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to create post")

    echo ""

    case mode
    of pmQueue:
        echo &"✅ Queued for {displayName}!"
    of pmSchedule:
        echo &"✅ Scheduled for {displayName}!"
    of pmDraft:
        echo &"✅ Draft saved for {displayName}!"
    of pmPublishNow:
        echo &"✅ Posted to {displayName}!"

    echo "   ID: " & res.val.post.id

    if res.val.post.status.isSome:
        echo "   Status: " & res.val.post.status.get


    # Only show platform URL when it actually published
    if mode == pmPublishNow and res.val.post.platforms.isSome:
        for p in res.val.post.platforms.get:
            if p.platformPostUrl.isSome:
                echo "   🔗 " & p.platformPostUrl.get


    if mode == pmQueue:
        tryPrintNextQueueSlot(apiKey, profileId)


# --------------------------------------------
# Quick-post variants (can be called directly)
# --------------------------------------------

proc runX*(args: seq[string]) =
    runPlatformPost("x", args)

proc runThreads*(args: seq[string]) =
    runPlatformPost("threads", args)

proc runInstagram*(args: seq[string]) =
    runPlatformPost("instagram", args)

proc runLinkedIn*(args: seq[string]) =
    runPlatformPost("linkedin", args)

proc runFacebook*(args: seq[string]) =
    runPlatformPost("facebook", args)

proc runTikTok*(args: seq[string]) =
    runPlatformPost("tiktok", args)

proc runBluesky*(args: seq[string]) =
    runPlatformPost("bluesky", args)

proc runYouTube*(args: seq[string]) =
    runPlatformPost("youtube", args)


# --------------------------------------------
# Thread (multi-tweet) commands
# --------------------------------------------

proc printThreadHelp*() =
    echo "gld thread - Create a thread (multi-tweet) on X or Threads"
    echo ""
    echo "Usage:"
    echo "  gld thread --platform x                # Interactive mode"
    echo "  gld thread --platform threads          # Post to Threads"
    echo "  gld thread --platform x --file items.json   # Load from JSON"
    echo ""
    echo "Options:"
    echo "  --platform <x|threads>  Target platform (required)"
    echo "  --file <path>           JSON file with thread items (see format below)"
    echo "  --comment <text>        Optional first comment after the thread"
    echo "  --schedule <time>       Schedule for later (ISO 8601)"
    echo "  --draft                 Save as draft instead of publishing"
    echo "  --queue                 Add to posting queue"
    echo "  --prof <name|id>        Profile name or ID to post from"
    echo "  --raw                   Print raw API response"
    echo "  --dry-run               Preview without posting"
    echo "  -h, --help              Show this help"
    echo ""
    echo "JSON Format:"
    echo "  ["
    echo "    {\"content\": \"1/ First tweet in the thread\"},"
    echo "    {\"content\": \"2/ Second tweet with image\", \"mediaFiles\": [\"/path/to/image.jpg\"]},"
    echo "    {\"content\": \"3/ Final tweet!\"}"
    echo "  ]"
    echo ""
    echo "Interactive Mode:"
    echo "  Without --file, you'll be prompted to enter each tweet in the thread."
    echo "  Enter an empty line to finish adding items."
    echo ""
    echo "Examples:"
    echo "  gld thread --platform x --file thread.json"
    echo "  gld thread --platform x --schedule 2024-12-25T10:00:00Z"
    echo "  gld thread --platform threads --draft"
    echo ""

type
    ThreadItemInput* = object
        content*: string
        mediaFiles*: seq[string]

proc parseThreadFromJson*(jsonPath: string): seq[ThreadItemInput] =
    ## Parse thread items from a JSON file
    if not fileExists(jsonPath):
        raise newException(ValueError, "File not found: " & jsonPath)
    
    let jsonStr = readFile(jsonPath)
    let data = parseJson(jsonStr)
    
    if data.kind != JArray:
        raise newException(ValueError, "Expected JSON array of thread items")
    
    for item in data:
        if not item.hasKey("content"):
            raise newException(ValueError, "Each thread item must have 'content'")
        
        var mediaFiles: seq[string]
        if item.hasKey("mediaFiles"):
            for m in item["mediaFiles"]:
                mediaFiles.add m.getStr
        
        result.add ThreadItemInput(
            content: item["content"].getStr
            ,mediaFiles: mediaFiles
        )

proc collectThreadItemsInteractive*(): seq[ThreadItemInput] =
    ## Collect thread items interactively from the user
    echo ""
    echo "🧵 Creating a thread"
    echo "Enter each tweet/post. Leave empty when done."
    echo ""
    
    var idx = 1
    while true:
        echo &"--- Item {idx} ---"
        let content = termuiAsk("Content:").strip
        
        if content.len == 0:
            break
        
        var mediaFiles: seq[string]
        let mediaAns = termuiAsk("Media files (comma-separated, optional):").strip
        if mediaAns.len > 0:
            mediaFiles = parseUserFileList(mediaAns)
            # Validate files exist
            for f in mediaFiles:
                if not fileExists(f):
                    raise newException(ValueError, "File not found: " & f)
        
        result.add ThreadItemInput(
            content: content
            ,mediaFiles: mediaFiles
        )
        
        idx += 1
        echo ""
    
    if result.len < 2:
        raise newException(ValueError, "A thread requires at least 2 items")

proc confirmThread*(
    platform: string
    ,items: seq[ThreadItemInput]
    ,firstComment: Option[string]
    ,mode: PostMode
    ,scheduledFor: Option[string]
): bool =
    ## Show thread preview and confirm
    let displayName = PlatformDisplayNames.getOrDefault(platform, platform)
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🧵 Thread Preview"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo &"📱 Platform: {displayName}"
    echo &"📝 Items: {items.len} tweets/posts"
    echo ""
    
    for i, item in items:
        echo &"  [{i+1}/{items.len}]"
        let maxWidth = 56
        var remaining = item.content
        while remaining.len > maxWidth:
            let breakPoint = remaining[0..<maxWidth].rfind(' ')
            let bp = if breakPoint > 0: breakPoint else: maxWidth
            echo "      " & remaining[0..<bp]
            remaining = remaining[bp..^1].strip
        if remaining.len > 0:
            echo "      " & remaining
        if item.mediaFiles.len > 0:
            echo &"      📎 {item.mediaFiles.len} media file(s)"
        echo ""
    
    if firstComment.isSome:
        echo &"💬 First comment: {firstComment.get}"
    
    case mode
    of pmDraft:
        echo "📋 Mode: Draft"
    of pmSchedule:
        echo &"⏰ Mode: Scheduled ({scheduledFor.get})"
    of pmQueue:
        echo "🗂️  Mode: Queue"
    of pmPublishNow:
        echo "🚀 Mode: Publish now"
    
    # Character limit warnings
    if platform == "twitter" or platform == "x":
        for i, item in items:
            if item.content.len > 280:
                echo &"⚠️  Warning: Item {i+1} exceeds Twitter limit ({item.content.len}/280 chars)"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    return termuiConfirm(&"Confirm {confirmVerb(mode)} thread?")

proc executeThread*(
    apiKey: string
    ,profileId: Option[string]
    ,platform: string
    ,items: seq[ThreadItemInput]
    ,firstComment: Option[string]
    ,mode: PostMode
    ,scheduledFor: Option[string]
): Future[Rz[late_posts.post_write_resp]] {.async.} =
    ## Execute thread creation
    
    # Get connected accounts
    let acctRes = await getConnectedPlatforms(apiKey, profileId)
    acctRes.isErr:
        return err[late_posts.post_write_resp](acctRes.err)
    
    # Find matching account
    var accountId = ""
    for a in acctRes.val:
        if a.platform == platform:
            accountId = a.accountId
            break
    
    if accountId.len == 0:
        let displayName = PlatformDisplayNames.getOrDefault(platform, platform)
        return err[late_posts.post_write_resp](&"No connected {displayName} account found")
    
    # Upload media for each thread item
    var threadItems: seq[threadItem]
    var totalMedia = 0
    
    if items.anyIt(it.mediaFiles.len > 0):
        let spinner = termuiSpinner("Uploading media...")
        
        for item in items:
            var mediaItems: seq[mediaItem]
            
            for filePath in item.mediaFiles:
                let uploadRes = await uploadMediaFile(apiKey, filePath)
                uploadRes.isErr:
                    spinner.complete()
                    return err[late_posts.post_write_resp](uploadRes.err)
                
                let cType = guessContentType(filePath)
                let mType =
                    if isVideoFile(cType): mediaItemTypes.video
                    elif isImageFile(cType): mediaItemTypes.image
                    else: mediaItemTypes.image
                
                mediaItems.add mediaItem(
                    url: uploadRes.val
                    ,`type`: mType
                )
                totalMedia += 1
            
            threadItems.add threadItem(
                content: item.content
                ,mediaItems: if mediaItems.len > 0: some(mediaItems) else: none(seq[mediaItem])
            )
        
        spinner.complete()
        echo &"✅ Uploaded {totalMedia} file(s)"
    else:
        for item in items:
            threadItems.add threadItem(
                content: item.content
                ,mediaItems: none(seq[mediaItem])
            )
    
    # Build platform entry
    let platformEntry =
        if platform == "twitter":
            pTwitterThread(accountId, threadItems, firstComment)
        else:
            pThreadsThread(accountId, threadItems, firstComment)
    
    # Determine publish flags
    var
        publishNow = none bool
        isDraft    = none bool
    
    if mode == pmDraft:
        isDraft = some true
    elif mode == pmPublishNow:
        publishNow = some true
    
    # Create the thread
    let spinnerLabel =
        case mode
        of pmDraft:      "Saving thread draft..."
        of pmSchedule:   "Scheduling thread..."
        of pmQueue:      "Queueing thread..."
        of pmPublishNow: "Publishing thread..."
    
    let spinner = termuiSpinner(spinnerLabel)
    
    let res = await late_posts.createPost(
        api_key       = apiKey
        ,content      = some(items[0].content)  # Use first item as top-level content
        ,platforms    = @[platformEntry]
        ,scheduledFor = scheduledFor
        ,publishNow   = publishNow
        ,isDraft      = isDraft
    )
    
    spinner.complete()
    return res

proc runThread*(args: seq[string]) =
    ## Create a thread (multi-tweet) on X or Threads
    
    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        printThreadHelp()
        return
    
    let conf = loadConfig()
    let apiKey = requireApiKey(conf)
    
    let
        rawMode      = hasFlag(args, "--raw")
        dryRun       = hasFlag(args, "--dry-run")
        isDraft      = hasFlag(args, "--draft")
        useQueue     = hasFlag(args, "--queue")
        platformArg  = pickArg(args, "--platform")
        fileArg      = pickArg(args, "--file")
        commentArg   = pickArg(args, "--comment")
        scheduleArg  = pickArg(args, "--schedule")
        profileArg   =
            if pickArg(args, "--prof").isSome: pickArg(args, "--prof")
            elif pickArg(args, "--profile").isSome: pickArg(args, "--profile")
            else: none string
    
    # Resolve profile
    let profileRes = resolveProfileIdSync(apiKey, profileArg, conf.profileId)
    profileRes.isErr:
        echo &"❌ {profileRes.err}"
        return
    
    let profileId = profileRes.val
    
    # Validate platform
    if platformArg.isNone:
        echo "❌ --platform is required (x or threads)"
        printThreadHelp()
        return
    
    let platform = normalizePlatform(platformArg.get)
    if platform.isNone or platform.get notin ["twitter", "threads"]:
        echo &"❌ Platform must be 'x' (twitter) or 'threads'"
        return
    
    let plat = platform.get
    
    # Collect thread items
    var items: seq[ThreadItemInput]
    
    if fileArg.isSome:
        # Load from JSON file
        try:
            items = parseThreadFromJson(fileArg.get)
        except CatchableError as e:
            echo &"❌ Failed to parse thread file: {e.msg}"
            return
    else:
        # Interactive mode
        try:
            items = collectThreadItemsInteractive()
        except CatchableError as e:
            echo &"❌ {e.msg}"
            return
    
    if items.len < 2:
        echo "❌ A thread requires at least 2 items. For single posts, use 'gld post'"
        return
    
    let firstComment =
        if commentArg.isSome and commentArg.get.len > 0: commentArg
        else: none(string)
    
    let mode =
        if isDraft: pmDraft
        elif scheduleArg.isSome: pmSchedule
        elif useQueue: pmQueue
        else: pmPublishNow
    
    let scheduledFor = scheduleArg
    
    # Confirm before posting
    if not dryRun:
        let confirmed = confirmThread(plat, items, firstComment, mode, scheduledFor)
        if not confirmed:
            echo "Cancelled."
            return
    
    if dryRun:
        echo &"🔍 Dry run - would create {items.len}-item thread on {PlatformDisplayNames.getOrDefault(plat, plat)}"
        return
    
    # Execute
    let res = waitFor executeThread(
        apiKey       = apiKey
        ,profileId   = profileId
        ,platform    = plat
        ,items       = items
        ,firstComment = firstComment
        ,mode        = mode
        ,scheduledFor = scheduledFor
    )
    
    res.isErr:
        icr res.err
        echo &"❌ Failed to create thread: {res.err}"
        return
    
    echo ""
    
    case mode
    of pmQueue:
        echo "✅ Thread queued for posting!"
    of pmSchedule:
        echo "✅ Thread scheduled!"
    of pmDraft:
        echo "✅ Thread draft saved!"
    of pmPublishNow:
        echo "✅ Thread published!"
    
    echo &"   ID: {res.val.post.id}"
    echo &"   Items: {items.len}"
    
    if res.val.post.status.isSome:
        echo &"   Status: {res.val.post.status.get}"
