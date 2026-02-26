## download_tools.nim - Download tools for GLD Agent
##
## Tools for downloading media from social platforms.

import
    std/[
        json
        ,asyncdispatch
        ,strformat
        ,options
        ,os
        ,strutils
        ,times
        ,algorithm
    ]

import
    llmm/tools

import
    ../lately/downloads as late_downloads
    ,../lately/download_providers as dl_providers
    ,../gld/src/store_config
    ,../gld/src/downloads_db as dl_db
    ,agent_config

# -----------------------------------------------------------------------------
# Platform Detection
# -----------------------------------------------------------------------------

proc detectPlatform(url: string): Option[string] =
    ## Auto-detect platform from URL
    let lowerUrl = url.toLowerAscii

    if "youtube.com" in lowerUrl or "youtu.be" in lowerUrl:
        return some("youtube")
    elif "instagram.com" in lowerUrl or "instagr.am" in lowerUrl:
        return some("instagram")
    elif "tiktok.com" in lowerUrl or "vm.tiktok" in lowerUrl:
        return some("tiktok")
    elif "twitter.com" in lowerUrl or "x.com" in lowerUrl:
        return some("twitter")
    elif "facebook.com" in lowerUrl or "fb.watch" in lowerUrl:
        return some("facebook")
    elif "linkedin.com" in lowerUrl:
        return some("linkedin")
    elif "bsky.app" in lowerUrl or "bsky.social" in lowerUrl:
        return some("bluesky")

    return none(string)

# -----------------------------------------------------------------------------
# Download Media Tool
# -----------------------------------------------------------------------------

proc DownloadMediaTool*(): Tool =
    ## Download media from a social media URL
    Tool(
        name        : "download_media"
        ,description: "Download media (video, images) from a social media URL. Supports YouTube, Instagram, TikTok, Twitter/X, Facebook, LinkedIn, and Bluesky."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "url": {
                    "type": "string"
                    ,"description": "The URL of the media to download"
                }
                ,"platform": {
                    "type": "string"
                    ,"description": "Platform hint (youtube, instagram, tiktok, twitter, facebook, linkedin, bluesky). Optional - will auto-detect if not provided."
                }
                ,"format": {
                    "type": "string"
                    ,"description": "Preferred format (mp4, mp3). Currently only used for YouTube."
                }
                ,"quality": {
                    "type": "string"
                    ,"description": "Preferred quality (e.g., 720p, 1080p). Currently only used for YouTube."
                }
                ,"outputDir": {
                    "type": "string"
                    ,"description": "Directory to save the downloaded file. Defaults to the configured download directory."
                }
            }
            ,"required": ["url"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                let url = args["url"].getStr

                # Get optional parameters
                let platformOpt = if args.hasKey("platform") and args["platform"].getStr.len > 0:
                    some(args["platform"].getStr)
                else:
                    none(string)

                let formatOpt = if args.hasKey("format") and args["format"].getStr.len > 0:
                    some(args["format"].getStr)
                else:
                    none(string)

                let qualityOpt = if args.hasKey("quality") and args["quality"].getStr.len > 0:
                    some(args["quality"].getStr)
                else:
                    none(string)

                let outputDir = if args.hasKey("outputDir") and args["outputDir"].getStr.len > 0:
                    args["outputDir"].getStr
                else:
                    getDownloadDir(conf)

                # Determine platform
                var platform = platformOpt.get("auto")
                if platform == "auto":
                    platform = detectPlatform(url).get("unknown")

                # Build request info
                var platformDisplay = platform
                if platform == "unknown":
                    return toolError("Could not detect platform from URL. Please specify the platform parameter.")

                # Confirm before downloading (safety)
                echo &"\n📥 Download Request:"
                echo &"   URL: {url}"
                echo &"   Platform: {platformDisplay}"
                echo &"   Output: {outputDir}"
                if formatOpt.isSome:
                    echo &"   Format: {formatOpt.get}"
                if qualityOpt.isSome:
                    echo &"   Quality: {qualityOpt.get}"
                echo ""

                # Confirm destructive action if enabled
                let agentConf = loadAgentConfig()
                if agentConf.confirmDestructive:
                    if not confirmDownload(url):
                        return toolSuccess(message = "Download cancelled by user")

                # Execute download using provider system (respects platform overrides)
                echo "Downloading..."

                # Build provider config from loaded config
                var providerConfig = dl_providers.ProviderConfig(
                    defaultProvider: conf.providerConfig.defaultProvider,
                    lateDevApiKey: apiKey,
                    instagApiKey: conf.providerConfig.instagApiKey,
                    platformProviders: conf.providerConfig.platformProviders
                )

                # Determine which provider to use for this platform
                let provider = dl_providers.getProviderForPlatform(providerConfig, platform)

                echo &"🔌 Using provider: {provider} for {platform}"

                # Execute download with the selected provider
                let dlResult = await dl_providers.downloadWithProvider(
                    provider,
                    providerConfig,
                    platform,
                    url,
                    outputDir,
                    format = formatOpt.get(""),
                    quality = qualityOpt.get("")
                )

                # Record download in database before processing result
                let db = dl_db.openDownloadsDb()
                var downloadId: int = 0

                if not dlResult.ok:
                    # Record failed download
                    let failedDownload = dl_db.recordDownload(
                        db = db
                        ,sourceUrl = url
                        ,filename = "unknown"
                        ,downloadPath = outputDir
                        ,platform = dl_db.detectPlatform(url)
                    )
                    downloadId = failedDownload.id
                    discard dl_db.updateDownloadStatus(db, downloadId, dl_db.dsFailed, some(dlResult.err))
                    return toolError(&"Download failed: {dlResult.err}")

                # Build success response with all downloaded files
                let results = dlResult.val
                if results.len == 0:
                    return toolError("No files were downloaded")

                var outputPaths: seq[JsonNode] = @[]
                for result in results:
                    outputPaths.add(%*result.filePath)
                    
                    # Record each successful download in database
                    let fileInfo = getFileInfo(result.filePath, followSymlink = true)
                    let (_, name, ext) = splitFile(result.filePath)
                    
                    # Detect content type from extension
                    var contentType = dl_db.dctUnknown
                    case ext.toLowerAscii()
                    of ".mp4", ".mov", ".avi", ".mkv", ".webm": contentType = dl_db.dctVideo
                    of ".mp3", ".wav", ".aac", ".ogg", ".flac": contentType = dl_db.dctAudio
                    of ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp": contentType = dl_db.dctImage
                    of ".pdf", ".doc", ".docx", ".txt", ".zip": contentType = dl_db.dctDocument
                    else: discard
                    
                    let download = dl_db.recordDownload(
                        db = db
                        ,sourceUrl = url
                        ,filename = name & ext
                        ,downloadPath = result.filePath
                        ,platform = dl_db.detectPlatform(url)
                        ,contentType = contentType
                        ,fileSize = some(fileInfo.size)
                        ,fileExtension = if ext.len > 0: some(ext[1..^1]) else: none(string)
                        ,tags = @[platform]
                    )
                    downloadId = download.id
                    discard dl_db.updateDownloadStatus(db, downloadId, dl_db.dsCompleted)

                return toolSuccess(%*{
                    "url": url
                    ,"platform": platform
                    ,"provider": $provider
                    ,"outputPaths": outputPaths
                    ,"fileCount": results.len
                    ,"recorded_in_db": true
                    ,"download_ids": downloadId
                }, &"Downloaded {results.len} file(s) to {outputDir} and recorded in database")

            except CatchableError as e:
                return toolError(&"Error downloading media: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Helper: Format file size
# -----------------------------------------------------------------------------

proc formatSize(size: int64): string =
    ## Format file size in human-readable format
    const KB = 1024
    const MB = 1024 * KB
    const GB = 1024 * MB
    const TB = 1024 * GB

    if size >= TB:
        result = fmt"{size.float / TB.float:.2f} TB"
    elif size >= GB:
        result = fmt"{size.float / GB.float:.2f} GB"
    elif size >= MB:
        result = fmt"{size.float / MB.float:.2f} MB"
    elif size >= KB:
        result = fmt"{size.float / KB.float:.2f} KB"
    else:
        result = fmt"{size} bytes"

# -----------------------------------------------------------------------------
# List Downloads Tool
# -----------------------------------------------------------------------------

proc ListDownloadsTool*(): Tool =
    ## List files in the downloads directory
    Tool(
        name        : "list_downloads"
        ,description: "List all downloaded files in the downloads directory. Shows file names, sizes, and modification dates."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "pattern": {
                    "type": "string"
                    ,"description": "Optional glob pattern to filter files (e.g., '*.mp4', '*.jpg', 'twitter_*'). Lists all files if not provided."
                }
                ,"sortBy": {
                    "type": "string"
                    ,"description": "Sort order: 'name', 'date', 'size'. Default is 'date' (newest first)."
                    ,"enum": ["name", "date", "size"]
                }
                ,"limit": {
                    "type": "integer"
                    ,"description": "Maximum number of files to return. Default is 50."
                }
            }
            ,"required": []
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let downloadDir = getDownloadDir(conf)

                # Check if directory exists
                if not dirExists(downloadDir):
                    return toolError(&"Download directory does not exist: {downloadDir}")

                # Get optional parameters
                let pattern = if args.hasKey("pattern") and args["pattern"].getStr.len > 0:
                    args["pattern"].getStr
                else:
                    "*"

                let sortBy = if args.hasKey("sortBy") and args["sortBy"].getStr.len > 0:
                    args["sortBy"].getStr
                else:
                    "date"

                let limit = if args.hasKey("limit") and args["limit"].kind == JInt:
                    args["limit"].getInt
                else:
                    50

                # List files matching pattern
                var files: seq[tuple[name: string, path: string, size: int64, modified: Time]] = @[]

                for filePath in walkFiles(downloadDir / pattern):
                    let info = getFileInfo(filePath)
                    let fileName = extractFilename(filePath)
                    files.add((
                        name: fileName
                        ,path: filePath
                        ,size: info.size
                        ,modified: info.lastWriteTime
                    ))

                # Sort files
                case sortBy:
                    of "name":
                        files.sort(proc(a, b: auto): int = cmp(a.name, b.name))
                    of "size":
                        files.sort(proc(a, b: auto): int = cmp(b.size, a.size))  # Largest first
                    else:  # date (default)
                        files.sort(proc(a, b: auto): int = cmp(b.modified, a.modified))  # Newest first

                # Apply limit
                if files.len > limit:
                    files = files[0 ..< limit]

                # Build response
                var fileList: seq[JsonNode] = @[]
                var totalSize: int64 = 0

                for file in files:
                    totalSize += file.size
                    fileList.add(%*{
                        "name": file.name
                        ,"path": file.path
                        ,"sizeBytes": file.size
                        ,"sizeHuman": formatSize(file.size)
                        ,"modified": $file.modified
                    })

                return toolSuccess(%*{
                    "directory": downloadDir
                    ,"pattern": pattern
                    ,"totalFiles": fileList.len
                    ,"totalSizeBytes": totalSize
                    ,"totalSizeHuman": formatSize(totalSize)
                    ,"files": fileList
                }, &"Found {fileList.len} file(s) in {downloadDir}")

            except CatchableError as e:
                return toolError(&"Error listing downloads: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Download Toolkit
# -----------------------------------------------------------------------------

proc DownloadToolkit*(): Toolkit =
    ## Toolkit for downloading media from social platforms
    result = newToolkit("lately_download", "Download media from social media platforms")
    result.add DownloadMediaTool()
    result.add ListDownloadsTool()
