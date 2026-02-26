## post_tools.nim - Posting tools for GLD Agent
##
## Tools for creating, scheduling, and managing posts.

import
    std/[
        json
        ,asyncdispatch
        ,strformat
        ,strutils
        ,options
        ,tables
        ,os
        ,mimetypes
    ]

import
    rz
    ,llmm/tools

import
    ../lately/posts as late_posts
    ,../lately/media as late_media
    ,../lately/accounts as late_accounts
    ,../lately/models
    ,../gld/src/store_config
    ,agent_config

# -----------------------------------------------------------------------------
# Helper: Get connected platforms
# -----------------------------------------------------------------------------

proc getConnectedPlatforms(apiKey: string): Future[Rz[seq[tuple[platform: string, accountId: string, username: string]]]] {.async.} =
    ## Fetches connected accounts and returns available platforms
    let res = await late_accounts.listAccounts(apiKey)

    if not res.ok:
        return err[seq[tuple[platform: string, accountId: string, username: string]]](res.err)

    var platforms: seq[tuple[platform: string, accountId: string, username: string]]
    for acct in res.val.accounts:
        platforms.add((
            platform: $acct.platform
            ,accountId: acct.id
            ,username: acct.username.get("")
        ))

    return ok(platforms)

# -----------------------------------------------------------------------------
# Helper: Guess content type
# -----------------------------------------------------------------------------

proc guessContentType(filePath: string): string =
    let sp = splitFile(filePath)
    var mt = newMimetypes()
    let ext = if sp.ext.startsWith("."): sp.ext[1 .. ^1] else: sp.ext
    result = mt.getMimetype(ext, default = "application/octet-stream")

proc isImageFile(contentType: string): bool =
    contentType.startsWith("image/")

proc isVideoFile(contentType: string): bool =
    contentType.startsWith("video/")

# -----------------------------------------------------------------------------
# Helper: Upload media file
# -----------------------------------------------------------------------------

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

    if not pres.ok:
        return err[string]("Presign failed: " & pres.err)

    # Upload
    let putRes = await late_media.mediaUploadToPresignedUrl(
        uploadUrl    = pres.val.uploadUrl
        ,file_path   = filePath
        ,contentType = cType
    )

    if not putRes.ok:
        return err[string]("Upload failed: " & putRes.err)

    return ok pres.val.publicUrl

# -----------------------------------------------------------------------------
# Create Post Tool
# -----------------------------------------------------------------------------

proc CreatePostTool*(): Tool =
    ## Create a post on social media platforms
    Tool(
        name        : "create_post"
        ,description: "Create and publish a post to one or more social media platforms. Supports X (Twitter), Threads, Instagram, LinkedIn, Facebook, TikTok, YouTube, and Bluesky. Can include media files and schedule for later."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "text": {
                    "type": "string"
                    ,"description": "The text content of the post"
                }
                ,"platforms": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "List of platforms to post to: twitter, threads, instagram, linkedin, facebook, tiktok, youtube, bluesky"
                }
                ,"mediaFiles": {
                    "type": "array"
                    ,"items": {"type": "string"}
                    ,"description": "Optional list of local file paths to attach as media"
                }
                ,"scheduleFor": {
                    "type": "string"
                    ,"description": "Optional ISO 8601 datetime to schedule the post (e.g., 2024-12-25T10:00:00Z)"
                }
                ,"isDraft": {
                    "type": "boolean"
                    ,"description": "If true, save as draft instead of publishing"
                }
                ,"useQueue": {
                    "type": "boolean"
                    ,"description": "If true, add to queue for next available slot"
                }
                ,"title": {
                    "type": "string"
                    ,"description": "Optional title (used for YouTube, LinkedIn articles)"
                }
                ,"linkedInOrganizationUrn": {
                    "type": "string"
                    ,"description": "LinkedIn only: Organization URN to post to a company page (e.g., 'urn:li:organization:123456'). If omitted, posts to personal profile."
                }
                ,"linkedInDocumentTitle": {
                    "type": "string"
                    ,"description": "LinkedIn only: Title for document/PDF posts. Required when posting PDFs/carousels to LinkedIn."
                }
                ,"disableLinkPreview": {
                    "type": "boolean"
                    ,"description": "LinkedIn only: Set to true to suppress automatic URL preview cards. Default: false"
                }
                ,"firstComment": {
                    "type": "string"
                    ,"description": "Optional first comment to auto-post after the main post publishes. Useful for external links on LinkedIn to avoid reach suppression."
                }
                ,"accountId": {
                    "type": "string"
                    ,"description": "Optional account ID to use for posting. If not provided, will use the first connected account for each platform."
                }
                ,"username": {
                    "type": "string"
                    ,"description": "Optional username (with or without @) to use for posting. If not provided, will use the first connected account for each platform."
                }
            }
            ,"required": ["text", "platforms"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                let text = args["text"].getStr

                # Parse platforms
                var platforms: seq[string]
                if args.hasKey("platforms"):
                    for p in args["platforms"]:
                        platforms.add p.getStr

                if platforms.len == 0:
                    return toolError("At least one platform must be specified")

                # Parse media files
                var mediaFiles: seq[string]
                if args.hasKey("mediaFiles"):
                    for m in args["mediaFiles"]:
                        mediaFiles.add m.getStr

                let scheduleFor = if args.hasKey("scheduleFor") and args["scheduleFor"].getStr.len > 0:
                    some(args["scheduleFor"].getStr)
                else:
                    none(string)

                let isDraft = args.hasKey("isDraft") and args["isDraft"].getBool
                let useQueue = args.hasKey("useQueue") and args["useQueue"].getBool
                let title = if args.hasKey("title") and args["title"].getStr.len > 0:
                    some(args["title"].getStr)
                else:
                    none(string)

                # Parse LinkedIn-specific options
                let linkedInOrganizationUrn = if args.hasKey("linkedInOrganizationUrn") and args["linkedInOrganizationUrn"].getStr.len > 0:
                    some(args["linkedInOrganizationUrn"].getStr)
                else:
                    none(string)

                let linkedInDocumentTitle = if args.hasKey("linkedInDocumentTitle") and args["linkedInDocumentTitle"].getStr.len > 0:
                    some(args["linkedInDocumentTitle"].getStr)
                else:
                    none(string)

                let disableLinkPreview = if args.hasKey("disableLinkPreview"):
                    some(args["disableLinkPreview"].getBool)
                else:
                    none(bool)

                let firstComment = if args.hasKey("firstComment") and args["firstComment"].getStr.len > 0:
                    some(args["firstComment"].getStr)
                else:
                    none(string)

                # Parse account targeting parameters
                let targetAccountId = if args.hasKey("accountId") and args["accountId"].getStr.len > 0:
                    some(args["accountId"].getStr)
                else:
                    none(string)

                let targetUsername = if args.hasKey("username") and args["username"].getStr.len > 0:
                    some(args["username"].getStr.replace("@", ""))  # Remove @ if present
                else:
                    none(string)

                # Get connected accounts
                let platformsRes = await getConnectedPlatforms(apiKey)
                if not platformsRes.ok:
                    return toolError(&"Failed to get connected accounts: {platformsRes.err}")

                # Build account map with targeting support
                var accountMap: Table[string, string]
                var usernameMap: Table[string, string]  # platform -> username
                
                for p in platformsRes.val:
                    # Check if this platform is requested
                    if p.platform notin platforms:
                        continue
                    
                    # Check if we're targeting a specific account
                    if targetAccountId.isSome:
                        if p.accountId == targetAccountId.get:
                            accountMap[p.platform] = p.accountId
                            usernameMap[p.platform] = p.username
                    elif targetUsername.isSome:
                        if p.username.toLowerAscii == targetUsername.get.toLowerAscii:
                            accountMap[p.platform] = p.accountId
                            usernameMap[p.platform] = p.username
                    else:
                        # No targeting - use first available (original behavior)
                        if not accountMap.hasKey(p.platform):
                            accountMap[p.platform] = p.accountId
                            usernameMap[p.platform] = p.username

                # Validate platforms have connected accounts
                var validPlatforms: seq[string]
                var missingPlatforms: seq[string]
                for p in platforms:
                    if accountMap.hasKey(p):
                        validPlatforms.add p
                    else:
                        missingPlatforms.add p

                if missingPlatforms.len > 0:
                    var errMsg = &"No connected account found for: {missingPlatforms.join(\", \")}."
                    if targetAccountId.isSome:
                        errMsg.add(&" (looking for accountId: {targetAccountId.get})")
                    elif targetUsername.isSome:
                        errMsg.add(&" (looking for username: @{targetUsername.get})")
                    errMsg.add(" Connect accounts at https://getlate.dev")
                    return toolError(errMsg)

                if validPlatforms.len == 0:
                    return toolError("No valid platform/account combinations found")

                # Confirm before posting (safety)
                echo "\n📝 Post Preview:"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                if text.len > 0:
                    echo ""
                    var remaining = text
                    while remaining.len > 60:
                        let breakPoint = remaining[0..<60].rfind(' ')
                        let bp = if breakPoint > 0: breakPoint else: 60
                        echo "  " & remaining[0..<bp]
                        remaining = remaining[bp..^1].strip
                    if remaining.len > 0:
                        echo "  " & remaining
                    echo ""

                echo "📱 Platforms & Accounts:"
                for plat in validPlatforms:
                    let username = usernameMap.getOrDefault(plat, "")
                    let accountId = accountMap.getOrDefault(plat, "")
                    if username.len > 0:
                        echo &"   • {plat}: @{username} ({accountId})"
                    else:
                        echo &"   • {plat}: {accountId}"

                if mediaFiles.len > 0:
                    echo &"📎 Media: {mediaFiles.len} file(s)"
                    for f in mediaFiles:
                        echo &"   - {f}"

                if isDraft:
                    echo "📋 Mode: Draft"
                elif scheduleFor.isSome:
                    echo &"⏰ Mode: Scheduled ({scheduleFor.get})"
                elif useQueue:
                    echo "🗂️  Mode: Queue"
                else:
                    echo "🚀 Mode: Publish now"

                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

                # ALWAYS confirm destructive action before posting/scheduling
                # This requires user confirmation and cannot be bypassed by the LLM
                let agentConf = loadAgentConfig()
                if agentConf.confirmDestructive:
                    if not confirmPostCreation(validPlatforms, isDraft, scheduleFor):
                        return toolSuccess(message = "Post creation cancelled by user")

                # Upload media files first
                var mediaItems: seq[mediaItem]
                if mediaFiles.len > 0:
                    echo "Uploading media..."

                    for filePath in mediaFiles:
                        let uploadRes = await uploadMediaFile(apiKey, filePath)

                        if not uploadRes.ok:
                            return toolError(&"Failed to upload {filePath}: {uploadRes.err}")

                        let cType = guessContentType(filePath)
                        let mType =
                            if isVideoFile(cType): mediaItemTypes.video
                            elif isImageFile(cType): mediaItemTypes.image
                            else: mediaItemTypes.image

                        let (_, name, ext) = splitFile(filePath)
                        let filename = name & ext

                        mediaItems.add mediaItem(
                            url      : uploadRes.val
                            ,`type`  : mType
                            ,filename : filename
                        )

                    echo "✅ Media uploaded"

                # Build platform entries
                var platformEntries: seq[platform]
                for plat in validPlatforms:
                    # For LinkedIn, include platform-specific data
                    if plat == "linkedin":
                        platformEntries.add pLinkedIn(
                            accountId        = accountMap[plat]
                            ,firstComment    = firstComment
                            ,disableLinkPreview = disableLinkPreview
                            ,organizationUrn  = linkedInOrganizationUrn
                            ,documentTitle    = linkedInDocumentTitle
                        )
                    else:
                        platformEntries.add platform(
                            platform  : plat
                            ,accountId: accountMap[plat]
                        )

                # Determine publish mode flags
                var
                    publishNow = none bool
                    draftFlag  = none bool

                if isDraft:
                    draftFlag = some true
                elif scheduleFor.isNone and not useQueue:
                    publishNow = some true

                # Create the post
                let actionLabel =
                    if isDraft:      "Saving draft..."
                    elif scheduleFor.isSome: "Scheduling..."
                    elif useQueue:   "Queueing..."
                    else:            "Publishing..."

                echo actionLabel

                let res = await late_posts.createPost(
                    api_key              = apiKey
                    ,content             = some(text)
                    ,title               = title
                    ,mediaItems          = mediaItems
                    ,platforms           = platformEntries
                    ,scheduledFor        = scheduleFor
                    ,publishNow          = publishNow
                    ,isDraft             = draftFlag
                )

                if not res.ok:
                    # Provide detailed error information for debugging
                    var detailedError = &"Post creation failed:\n"
                    detailedError.add &"  Error: {res.err}\n"
                    detailedError.add &"  Platforms: {validPlatforms.join(\", \")}\n"
                    detailedError.add &"  Text length: {text.len} chars\n"
                    if isDraft:
                        detailedError.add &"  Mode: Draft\n"
                    elif scheduleFor.isSome:
                        detailedError.add &"  Mode: Scheduled for {scheduleFor.get}\n"
                    elif useQueue:
                        detailedError.add &"  Mode: Queue\n"
                    else:
                        detailedError.add &"  Mode: Publish now\n"
                    detailedError.add &"\nPossible causes:\n"
                    detailedError.add &"  - Token expired or missing required scopes\n"
                    detailedError.add &"  - Rate limit / velocity limit\n"
                    detailedError.add &"  - Character limit exceeded for platform\n"
                    detailedError.add &"  - Account disconnected or missing permissions\n"
                    detailedError.add &"\nUse check_account_health to verify account status."
                    return toolError(detailedError)

                let post = res.val.post
                return toolSuccess(%*{
                    "postId": post.id
                    ,"platforms": validPlatforms
                    ,"status": post.status.get("")
                    ,"scheduledFor": post.scheduledFor.get("")
                }, &"Post created successfully! ID: {post.id}")

            except CatchableError as e:
                return toolError(&"Error creating post: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Post Toolkit
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Create Thread Tool
# -----------------------------------------------------------------------------

proc CreateThreadTool*(): Tool =
    ## Create a thread (multi-tweet) on X (Twitter) or Threads
    Tool(
        name        : "create_thread"
        ,description: "Create and publish a thread (multiple connected posts) on X (Twitter) or Threads. Each item in the thread can have its own text and optional media. Perfect for long-form content that exceeds single-post character limits."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "platform": {
                    "type": "string"
                    ,"enum": ["twitter", "threads"]
                    ,"description": "Platform to post the thread to: 'twitter' for X/Twitter, 'threads' for Meta Threads"
                }
                ,"threadItems": {
                    "type": "array"
                    ,"items": {
                        "type": "object"
                        ,"properties": {
                            "content": {
                                "type": "string"
                                ,"description": "Text content for this thread item (tweet/post). Keep under 280 chars for Twitter free accounts."
                            }
                            ,"mediaFiles": {
                                "type": "array"
                                ,"items": {"type": "string"}
                                ,"description": "Optional list of local file paths to attach to this specific thread item (max 4 images or 1 video per item)"
                            }
                        }
                        ,"required": ["content"]
                    }
                    ,"description": "Array of thread items. Each item becomes a reply to the previous one. Minimum 2 items for a thread."
                }
                ,"firstComment": {
                    "type": "string"
                    ,"description": "Optional first comment to post after the thread is published"
                }
                ,"scheduleFor": {
                    "type": "string"
                    ,"description": "Optional ISO 8601 datetime to schedule the thread (e.g., 2024-12-25T10:00:00Z)"
                }
                ,"isDraft": {
                    "type": "boolean"
                    ,"description": "If true, save as draft instead of publishing"
                }
                ,"useQueue": {
                    "type": "boolean"
                    ,"description": "If true, add to queue for next available slot"
                }
                ,"accountId": {
                    "type": "string"
                    ,"description": "Optional account ID to use for posting. If not provided, will use the first connected account for the platform."
                }
                ,"username": {
                    "type": "string"
                    ,"description": "Optional username (with or without @) to use for posting. If not provided, will use the first connected account for the platform."
                }
            }
            ,"required": ["platform", "threadItems"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                let platform = args["platform"].getStr.toLowerAscii

                if platform notin ["twitter", "threads"]:
                    return toolError("Platform must be either 'twitter' or 'threads'")

                # Parse thread items
                var threadItems: seq[threadItem]
                if not args.hasKey("threadItems") or args["threadItems"].len == 0:
                    return toolError("At least one thread item is required")

                if args["threadItems"].len < 2:
                    return toolError("A thread requires at least 2 items. For single posts, use create_post instead.")

                for item in args["threadItems"]:
                    let content = item["content"].getStr
                    var mediaItems: seq[mediaItem]

                    if item.hasKey("mediaFiles"):
                        for m in item["mediaFiles"]:
                            let filePath = m.getStr
                            if not fileExists(filePath):
                                return toolError(&"Media file not found: {filePath}")

                            let uploadRes = await uploadMediaFile(apiKey, filePath)
                            if not uploadRes.ok:
                                return toolError(&"Failed to upload {filePath}: {uploadRes.err}")

                            let cType = guessContentType(filePath)
                            let mType =
                                if isVideoFile(cType): mediaItemTypes.video
                                elif isImageFile(cType): mediaItemTypes.image
                                else: mediaItemTypes.image

                            let (_, name, ext) = splitFile(filePath)
                            let filename = name & ext

                            mediaItems.add mediaItem(
                                url      : uploadRes.val
                                ,`type`  : mType
                                ,filename : filename
                            )

                    threadItems.add threadItem(
                        content    : content
                        ,mediaItems: if mediaItems.len > 0: some(mediaItems) else: none(seq[mediaItem])
                    )

                let firstComment = if args.hasKey("firstComment") and args["firstComment"].getStr.len > 0:
                    some(args["firstComment"].getStr)
                else:
                    none(string)

                let scheduleFor = if args.hasKey("scheduleFor") and args["scheduleFor"].getStr.len > 0:
                    some(args["scheduleFor"].getStr)
                else:
                    none(string)

                let isDraft = args.hasKey("isDraft") and args["isDraft"].getBool
                let useQueue = args.hasKey("useQueue") and args["useQueue"].getBool

                # Parse account targeting parameters
                let targetAccountId = if args.hasKey("accountId") and args["accountId"].getStr.len > 0:
                    some(args["accountId"].getStr)
                else:
                    none(string)

                let targetUsername = if args.hasKey("username") and args["username"].getStr.len > 0:
                    some(args["username"].getStr.replace("@", ""))  # Remove @ if present
                else:
                    none(string)

                # Get connected accounts
                let platformsRes = await getConnectedPlatforms(apiKey)
                if not platformsRes.ok:
                    return toolError(&"Failed to get connected accounts: {platformsRes.err}")

                # Find account for the platform (with targeting support)
                var accountId = ""
                var accountUsername = ""
                
                for p in platformsRes.val:
                    if p.platform == platform:
                        # Check if we're targeting a specific account
                        if targetAccountId.isSome:
                            if p.accountId == targetAccountId.get:
                                accountId = p.accountId
                                accountUsername = p.username
                                break
                        elif targetUsername.isSome:
                            if p.username.toLowerAscii == targetUsername.get.toLowerAscii:
                                accountId = p.accountId
                                accountUsername = p.username
                                break
                        else:
                            # No targeting - use first available
                            if accountId.len == 0:
                                accountId = p.accountId
                                accountUsername = p.username
                            # Don't break - continue in case we find a targeted match later

                if accountId.len == 0:
                    var errMsg = &"No connected account found for {platform}"
                    if targetAccountId.isSome:
                        errMsg.add(&" with accountId '{targetAccountId.get}'")
                    elif targetUsername.isSome:
                        errMsg.add(&" with username '{targetUsername.get}'")
                    errMsg.add(". Connect your account at https://getlate.dev")
                    return toolError(errMsg)

                # Build platform entry
                let platformEntry =
                    if platform == "twitter":
                        pTwitterThread(accountId, threadItems, firstComment)
                    else:
                        pThreadsThread(accountId, threadItems, firstComment)

                # Preview
                let platformDisplay = if platform == "twitter": "X (Twitter)" else: "Threads"
                echo "\n🧵 Thread Preview:"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo &"📱 Platform: {platformDisplay}"
                echo &"📝 Items: {threadItems.len} tweets/posts"
                echo ""

                for i, item in threadItems:
                    echo &"  [{i+1}/{threadItems.len}]"
                    var remaining = item.content
                    while remaining.len > 56:  # Indent + 2 chars for "  "
                        let breakPoint = remaining[0..<56].rfind(' ')
                        let bp = if breakPoint > 0: breakPoint else: 56
                        echo "      " & remaining[0..<bp]
                        remaining = remaining[bp..^1].strip
                    if remaining.len > 0:
                        echo "      " & remaining
                    if item.mediaItems.isSome and item.mediaItems.get.len > 0:
                        echo &"      📎 {item.mediaItems.get.len} media item(s)"
                    echo ""

                if firstComment.isSome:
                    echo &"💬 First comment: {firstComment.get}"
                if accountUsername.len > 0:
                    echo &"👤 Account: @{accountUsername}"
                if isDraft:
                    echo "📋 Mode: Draft"
                elif scheduleFor.isSome:
                    echo &"⏰ Mode: Scheduled ({scheduleFor.get})"
                elif useQueue:
                    echo "🗂️  Mode: Queue"
                else:
                    echo "🚀 Mode: Publish now"

                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

                # ALWAYS confirm destructive action before posting/scheduling
                # This requires user confirmation and cannot be bypassed by the LLM
                let agentConf = loadAgentConfig()
                if agentConf.confirmDestructive:
                    if not confirmPostCreation(@[platform], isDraft, scheduleFor):
                        return toolSuccess(message = "Thread creation cancelled by user")

                # Determine publish mode flags
                var
                    publishNow = none bool
                    draftFlag  = none bool

                if isDraft:
                    draftFlag = some true
                elif scheduleFor.isNone and not useQueue:
                    publishNow = some true

                # Create the thread
                let actionLabel =
                    if isDraft:      "Saving thread draft..."
                    elif scheduleFor.isSome: "Scheduling thread..."
                    elif useQueue:   "Queueing thread..."
                    else:            "Publishing thread..."

                echo actionLabel

                let res = await late_posts.createPost(
                    api_key              = apiKey
                    ,content             = some(threadItems[0].content)  # Use first item as top-level content
                    ,platforms           = @[platformEntry]
                    ,scheduledFor        = scheduleFor
                    ,publishNow          = publishNow
                    ,isDraft             = draftFlag
                )

                if not res.ok:
                    # Provide detailed error information for debugging
                    var detailedError = &"Thread creation failed:\n"
                    detailedError.add &"  Error: {res.err}\n"
                    detailedError.add &"  Platform: {platform}\n"
                    detailedError.add &"  Account ID: {accountId}\n"
                    if accountUsername.len > 0:
                        detailedError.add &"  Username: @{accountUsername}\n"
                    detailedError.add &"  Thread items: {threadItems.len}\n"
                    if isDraft:
                        detailedError.add &"  Mode: Draft\n"
                    elif scheduleFor.isSome:
                        detailedError.add &"  Mode: Scheduled for {scheduleFor.get}\n"
                    elif useQueue:
                        detailedError.add &"  Mode: Queue\n"
                    else:
                        detailedError.add &"  Mode: Publish now\n"
                    detailedError.add &"\nPossible causes:\n"
                    detailedError.add &"  - Token expired or missing required scopes (tweet.write)\n"
                    detailedError.add &"  - Rate limit / velocity limit\n"
                    detailedError.add &"  - Invalid payload (check threadItems format)\n"
                    detailedError.add &"  - Account disconnected or wrong account selected\n"
                    detailedError.add &"\nUse check_account_health to verify account status."
                    return toolError(detailedError)

                let post = res.val.post
                return toolSuccess(%*{
                    "postId": post.id
                    ,"platform": platform
                    ,"status": post.status.get("")
                    ,"scheduledFor": post.scheduledFor.get("")
                    ,"threadItems": threadItems.len
                }, &"Thread created successfully! ID: {post.id} ({threadItems.len} items)")

            except CatchableError as e:
                return toolError(&"Error creating thread: {e.msg}")
    )

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# List Posts Tool
# -----------------------------------------------------------------------------

proc ListPostsTool*(): Tool =
    ## List posts with optional filtering by status, platform, date range
    Tool(
        name        : "list_posts"
        ,description: "List posts from your Late.dev account with optional filtering. Returns scheduled posts, published posts, drafts, or failed posts. Useful for reviewing what content is scheduled or has been published."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "status": {
                    "type": "string"
                    ,"enum": ["", "scheduled", "published", "draft", "failed", "processing"]
                    ,"description": "Filter by post status. Empty string returns all posts. Options: scheduled, published, draft, failed, processing"
                }
                ,"platform": {
                    "type": "string"
                    ,"description": "Filter by platform (twitter, threads, instagram, linkedin, facebook, tiktok, youtube, bluesky)"
                }
                ,"limit": {
                    "type": "integer"
                    ,"description": "Maximum number of posts to return (default: 20, max: 100)"
                    ,"default": 20
                }
                ,"page": {
                    "type": "integer"
                    ,"description": "Page number for pagination (default: 1)"
                    ,"default": 1
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                # Parse parameters
                let status = if args.hasKey("status"): args["status"].getStr else: ""
                let platform = if args.hasKey("platform"): args["platform"].getStr else: ""
                let limit = if args.hasKey("limit"): args["limit"].getInt else: 20
                let page = if args.hasKey("page"): args["page"].getInt else: 1

                let statusDisplay = if status.len > 0: status else: "all"
                echo &"Fetching posts (status: {statusDisplay}, limit: {limit})..."

                let res = await late_posts.listPosts(
                    api_key      = apiKey
                    ,page        = page
                    ,limit       = limit
                    ,status      = status
                    ,platform    = platform
                )

                if not res.ok:
                    return toolError(&"Failed to fetch posts: {res.err}")

                let posts = res.val.posts
                let pagination = res.val.pagination

                if posts.len == 0:
                    let filterDesc = if status.len > 0: &" with status '{status}'" else: ""
                    return toolSuccess(message = &"No posts found{filterDesc}.")

                # Build response data
                var postsJson = newJArray()
                
                echo &"\n📋 Posts ({posts.len} found):"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                
                # Table header
                echo "│ ID                    │ Status     │ Scheduled For        │ Platforms              │ Content Preview"
                echo "├───────────────────────┼────────────┼──────────────────────┼────────────────────────┼────────────────────────────────────────"
                
                for post in posts:
                    var postObj = newJObject()
                    postObj["id"] = % post.id
                    postObj["status"] = % post.status.get("")
                    postObj["scheduledFor"] = % post.scheduledFor.get("")
                    
                    # Extract content preview
                    let content = post.content.get("")
                    let preview = if content.len > 40: content[0..<40] & "..." else: content
                    
                    # Get platforms
                    var platforms: seq[string]
                    if post.platforms.isSome:
                        for p in post.platforms.get:
                            platforms.add p.platform
                    let platformsStr = platforms.join(", ")
                    
                    # Get status with emoji
                    let statusDisplay = case post.status.get(""):
                        of "scheduled": "⏰ scheduled"
                        of "published": "✅ published"
                        of "draft": "📝 draft"
                        of "failed": "❌ failed"
                        of "processing": "🔄 processing"
                        else: "❓ " & post.status.get("")
                    
                    # Format scheduled time
                    let scheduledStr = post.scheduledFor.get("N/A")
                    
                    # Truncate fields for table display
                    let idTrunc = if post.id.len > 21: post.id[0..<21] else: post.id
                    let schedTrunc = if scheduledStr.len > 20: scheduledStr[0..<20] else: scheduledStr
                    let platTrunc = if platformsStr.len > 22: platformsStr[0..<22] else: platformsStr
                    
                    echo &"│ {idTrunc:<21} │ {statusDisplay:<10} │ {schedTrunc:<20} │ {platTrunc:<22} │ {preview}"
                    
                    # Add to JSON array
                    postObj["content"] = % content
                    postObj["platforms"] = % platforms
                    if post.title.isSome:
                        postObj["title"] = % post.title.get
                    if post.publishedAt.isSome:
                        postObj["publishedAt"] = % post.publishedAt.get
                    if post.createdAt.isSome:
                        postObj["createdAt"] = % post.createdAt.get
                    
                    postsJson.add postObj
                
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                
                # Show pagination info if available
                if pagination.isSome:
                    let pg = pagination.get
                    echo &"\n📄 Page {pg.page} of {pg.pages} | Total: {pg.total} posts"
                
                echo ""

                let filterDesc = if status.len > 0: &" with status '{status}'" else: ""
                return toolSuccess(%*{
                    "posts": postsJson
                    ,"count": posts.len
                    ,"page": page
                    ,"totalPages": if pagination.isSome: pagination.get.pages else: 1
                    ,"totalPosts": if pagination.isSome: pagination.get.total else: posts.len
                }, &"Found {posts.len} post(s){filterDesc}")

            except CatchableError as e:
                return toolError(&"Error fetching posts: {e.msg}")
    )

# -----------------------------------------------------------------------------
# List LinkedIn Organizations Tool
# -----------------------------------------------------------------------------

proc ListLinkedInOrganizationsTool*(): Tool =
    ## List LinkedIn organizations (company pages) available to a connected account
    Tool(
        name        : "list_linkedin_organizations"
        ,description: "List LinkedIn organizations (company pages) that a connected account can post to. Use this to get organization URNs for posting to company pages instead of personal profiles."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "accountId": {
                    "type": "string"
                    ,"description": "The LinkedIn account ID to check for organizations. Get this from list_connected_accounts."
                }
            }
            ,"required": ["accountId"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)
                let accountId = args["accountId"].getStr

                echo "Fetching LinkedIn organizations..."

                let res = await late_accounts.getLinkedInOrganizations(apiKey, accountId)

                if not res.ok:
                    return toolError(&"Failed to fetch LinkedIn organizations: {res.err}")

                if res.val.organizations.len == 0:
                    return toolSuccess(message = "No LinkedIn organizations found for this account. The account can only post to personal profile.")

                var orgsJson = newJArray()
                echo &"\n📋 LinkedIn Organizations ({res.val.organizations.len} found):"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                for org in res.val.organizations:
                    var orgObj = newJObject()
                    orgObj["urn"] = % org.urn
                    orgObj["name"] = % org.name
                    if org.vanityName.isSome:
                        orgObj["vanityName"] = % org.vanityName.get
                    if org.logoUrl.isSome:
                        orgObj["logoUrl"] = % org.logoUrl.get
                    orgsJson.add orgObj

                    echo &"\n  📌 {org.name}"
                    echo &"     URN: {org.urn}"
                    if org.vanityName.isSome:
                        echo &"     Vanity: {org.vanityName.get}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

                return toolSuccess(%*{
                    "organizations": orgsJson
                    ,"count": res.val.organizations.len
                }, &"Found {res.val.organizations.len} LinkedIn organization(s)")

            except CatchableError as e:
                return toolError(&"Error fetching LinkedIn organizations: {e.msg}")
    )
# Post Toolkit
# -----------------------------------------------------------------------------

proc PostToolkit*(): Toolkit =
    ## Toolkit for creating and managing posts
    result = newToolkit("lately_post", "Create and manage social media posts and threads")
    result.add CreatePostTool()
    result.add CreateThreadTool()
    result.add ListPostsTool()
    result.add ListLinkedInOrganizationsTool()
