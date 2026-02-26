# src/gld/cmd_download.nim
##
## Download command for GLD CLI
##
## Downloads media from social platforms using configurable providers
##
## Usage:
##   gld download <url>                    # Download from URL (auto-detect platform)
##   gld download <url> --out <path>       # Download to specific path
##   gld download <url> --platform <p>     # Specify platform (youtube, instagram, tiktok, twitter, facebook, linkedin, bluesky)
##   gld download <url> --provider <p>     # Specify provider (latedev, instag)
##   gld download <url> --format mp4       # Request specific format (youtube)
##   gld download <url> --quality 720p     # Request specific quality (youtube)

import
    std/[
        strformat
        ,strutils
        ,sequtils
        ,options
        ,asyncdispatch
        ,os
        ,times
        ,json
    ]

import
    rz
    ,termui
    ,ic

import
    ../../lately/downloads as late_downloads
    ,../../lately/download_providers as providers
    ,store_config
    ,types


# --------------------------------------------
# Platform detection
# --------------------------------------------

proc detectPlatform*(url: string): Option[string] =
    ## Auto-detect platform from URL
    let lowerUrl = url.toLowerAscii
    
    if "youtube.com" in lowerUrl or "youtu.be" in lowerUrl:
        return some("youtube")
    elif "instagram.com" in lowerUrl or "instagr.am" in lowerUrl:
        return some("instagram")
    elif "tiktok.com" in lowerUrl:
        return some("tiktok")
    elif "twitter.com" in lowerUrl or "x.com" in lowerUrl:
        return some("twitter")
    elif "facebook.com" in lowerUrl or "fb.watch" in lowerUrl:
        return some("facebook")
    elif "linkedin.com" in lowerUrl:
        return some("linkedin")
    elif "bsky.app" in lowerUrl or "bluesky" in lowerUrl:
        return some("bluesky")
    
    return none(string)


proc normalizePlatform*(input: string): Option[string] =
    ## Normalize platform name
    let lower = input.toLowerAscii.strip
    
    case lower
    of "youtube", "yt":
        return some("youtube")
    of "instagram", "ig", "insta":
        return some("instagram")
    of "tiktok", "tt":
        return some("tiktok")
    of "twitter", "x", "tw":
        return some("twitter")
    of "facebook", "fb":
        return some("facebook")
    of "linkedin", "li":
        return some("linkedin")
    of "bluesky", "bsky":
        return some("bluesky")
    else:
        return none(string)


# --------------------------------------------
# Provider detection/selection
# --------------------------------------------

proc detectProvider(providerArg: Option[string], conf: GldConfig, platform: string): DownloadProviderKind =
    ## Determine which provider to use
    ## Priority: CLI arg > platform override > default
    
    if providerArg.isSome:
        let parsed = parseDownloadProviderKind(providerArg.get)
        if parsed.isSome:
            return parsed.get
        else:
            echo &"⚠️  Unknown provider '{providerArg.get}', using default"
    
    # Use platform override or default
    result = getProviderForPlatform(conf, platform)


# --------------------------------------------
# Arg parsing helpers
# --------------------------------------------

proc pickArg(
    args                : seq[string]
    ,key                : string
)                       : Option[string] =
    ## Supports --key=value and --key value formats
    for i, a in args:
        if a.startsWith(key & "="):
            return some a.split("=", 1)[1].strip
        if a == key and i + 1 < args.len:
            return some args[i + 1].strip
    return none(string)


proc hasFlag(
    args                : seq[string]
    ,key                : string
)                       : bool =
    result = args.anyIt(it == key)


proc getPositionalUrl(args: seq[string]): Option[string] =
    ## Gets the first non-flag argument as the URL
    for a in args:
        if not a.startsWith("-") and not a.startsWith("--"):
            return some a
    return none(string)


# --------------------------------------------
# Help
# --------------------------------------------

proc generateOutputPath(url: string, platform: string, conf: GldConfig): string =
    ## Generate a default output path for a URL
    ## Format: {downloadDir}/{platform}_{timestamp}.mp4
    
    let downloadDir = getDownloadDir(conf)
    let timestamp = format(getTime(), "yyyyMMdd'-'HHmmss")
    let filename = &"{platform}_{timestamp}.mp4"
    
    return downloadDir / filename


proc printDownloadHelp*() =
    echo "gld download - Download media from social platforms"
    echo ""
    echo "Usage:"
    echo "  gld download <url>                     Download from URL (auto-detect platform)"
    echo "  gld download <url> --out <path>        Download to specific path"
    echo "  gld download <url> -o <path>           Short form for --out"
    echo "  gld download <url> --platform <p>      Specify platform (optional)"
    echo "  gld download <url> --provider <p>      Specify provider (latedev, instag)"
    echo "  gld download <url> --format <fmt>      Request format (mp4, webm) - YouTube only"
    echo "  gld download <url> --quality <q>       Request quality (360p/480p/720p/1080p) - YouTube only"
    echo "  gld download <url> --debug             Show debug output"
    echo ""
    echo "Supported Platforms:"
    echo "  youtube, instagram, tiktok, twitter, facebook, linkedin, bluesky"
    echo ""
    echo "Download Providers:"
    echo "  latedev    Late.dev in-house API (default, works for most platforms)"
    echo "  instag     Instag.com API (better for Instagram and Twitter/X)"
    echo ""
    echo "Provider Configuration:"
    echo "  Configure default provider and per-platform overrides with:"
    echo "    gld config --provider <provider> [--platform <platform>]"
    echo ""
    echo "  Set Instag API key:"
    echo "    gld config --provider instag --apikey <your-key>"
    echo ""
    echo "Download Location:"
    echo "  By default, files are saved to .gld/downloads/ with the filename format:"
    echo "    {platform}_{timestamp}.mp4  (e.g., youtube_20250115-143022.mp4)"
    echo ""
    echo "  To configure a custom default download directory, set downloadDir in:"
    echo "    .gld/gld.config.json"
    echo ""
    echo "Notes:"
    echo "  - Provider is auto-selected based on config or can be overridden with --provider"
    echo "  - Late.dev's in-house API doesn't work well for Twitter/X - use Instag instead"
    echo "  - YouTube downloads may have separate video/audio streams."
    echo "    Use --format mp4 --quality 720p for merged audio/video."
    echo "  - Platform is auto-detected from URL, but can be overridden with --platform"
    echo ""
    echo "Examples:"
    echo "  gld download \"https://youtube.com/watch?v=...\""
    echo "  gld download \"https://x.com/user/status/...\" --provider instag"
    echo "  gld download \"https://instagram.com/p/...\" --provider instag --out ./downloads"
    echo "  gld download \"https://youtube.com/watch?v=...\" --format mp4 --quality 720p"
    echo ""


# --------------------------------------------
# Download execution with providers
# --------------------------------------------

proc executeDownloadWithProvider*(
    conf: GldConfig
    ,url: string
    ,platform: string
    ,provider: DownloadProviderKind
    ,outPath: Option[string]
    ,format: Option[string] = none(string)
    ,quality: Option[string] = none(string)
    ,debug: bool = false
): Future[rz.Rz[seq[string]]] {.async.} =
    ## Execute download using the specified provider
    
    echo &"⏳ Fetching download info..."
    echo &"🔌 Using provider: {$provider}"
    
    # Prepare output directory
    let downloadDir = getDownloadDir(conf)
    var outDir = downloadDir
    
    if outPath.isSome:
        let theOutPath = outPath.get
        if theOutPath.endsWith("/") or theOutPath.endsWith("\\") or dirExists(theOutPath):
            # It's a directory
            outDir = theOutPath
            if not dirExists(outDir):
                createDir(outDir)
        else:
            # It's a file path - use its directory
            outDir = splitFile(theOutPath).dir
            if outDir.len > 0 and not dirExists(outDir):
                createDir(outDir)
    
    # Prepare provider config
    var providerConfig = providers.defaultProviderConfig()
    providerConfig.defaultProvider = conf.providerConfig.defaultProvider
    providerConfig.lateDevApiKey = conf.apiKey
    providerConfig.instagApiKey = conf.providerConfig.instagApiKey
    providerConfig.platformProviders = @[]  # We already resolved the provider
    
    # Execute download based on provider
    case provider
    of dpkLateDev:
        # Use original Late.dev implementation
        var downloadResult: rz.Rz[string]
        
        case platform
        of "youtube":
            let fmt = if format.isSome: format.get else: ""
            let ql = if quality.isSome: quality.get else: ""
            downloadResult = await late_downloads.youtubeDownload(conf.apiKey, url, format = fmt, quality = ql)
        of "instagram":
            downloadResult = await late_downloads.instagramDownload(conf.apiKey, url)
        of "tiktok":
            downloadResult = await late_downloads.tiktokDownload(conf.apiKey, url)
        of "twitter":
            downloadResult = await late_downloads.twitterDownload(conf.apiKey, url)
        of "facebook":
            downloadResult = await late_downloads.facebookDownload(conf.apiKey, url)
        of "linkedin":
            downloadResult = await late_downloads.linkedinDownload(conf.apiKey, url)
        of "bluesky":
            downloadResult = await late_downloads.blueskyDownload(conf.apiKey, url)
        else:
            return rz.err[seq[string]]("Unsupported platform: " & platform)
        
        downloadResult.isErr:
            return rz.err[seq[string]]("Failed to get download URL: " & downloadResult.err)
        
        # Debug: show raw response
        if debug:
            echo ""
            echo "━━━ DEBUG: API Response ━━━"
            echo downloadResult.val
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
        
        # Parse response to get download URL
        var downloadUrl: string
        var hasAudio = true
        
        try:
            let jsonResp = parseJson(downloadResult.val)
            
            downloadUrl = jsonResp{"downloadUrl"}.getStr()
            hasAudio = jsonResp{"hasAudio"}.getBool(true)
            
            # Check for formats array (might contain audio/video merge info)
            if jsonResp.hasKey("formats") and not hasAudio:
                for fmt in jsonResp{"formats"}:
                    let fmtHasAudio = fmt{"hasAudio"}.getBool(false)
                    if fmtHasAudio:
                        let altUrl = fmt{"url"}.getStr("")
                        if altUrl.len > 0:
                            if debug:
                                echo &"Found alternative format with audio"
                            downloadUrl = altUrl
                            hasAudio = true
                            break
            
            if downloadUrl.len == 0:
                return rz.err[seq[string]]("No download URL in response")
                
        except CatchableError as e:
            return rz.err[seq[string]]("Failed to parse response: " & e.msg)
        
        if debug:
            echo &"Download URL: {downloadUrl}"
            echo &"Has audio: {hasAudio}"
            echo ""
        
        if not hasAudio:
            echo "⚠️  Warning: This download may not include audio (DASH stream detected)."
            echo "   Try using: --format mp4 --quality 720p"
            echo ""
        
        # Determine output path
        var finalOutPath: string
        if outPath.isSome:
            finalOutPath = outPath.get
            # If output is a directory, generate filename
            if dirExists(finalOutPath) or finalOutPath.endsWith("/") or finalOutPath.endsWith("\\"):
                let timestamp = format(getTime(), "yyyyMMdd'-'HHmmss")
                finalOutPath = finalOutPath / &"{platform}_{timestamp}_latedev.mp4"
        else:
            finalOutPath = generateOutputPath(url, platform, conf)
        
        # Ensure output directory exists
        let outDirPath = splitFile(finalOutPath).dir
        if outDirPath.len > 0 and not dirExists(outDirPath):
            createDir(outDirPath)
        
        # Download the file
        echo &"⬇️  Downloading to {finalOutPath}..."
        let dlResult = await late_downloads.downloadFileFromUrl(downloadUrl, finalOutPath)
        
        dlResult.isErr:
            return rz.err[seq[string]]("Download failed: " & dlResult.err)
        
        return rz.ok(@[finalOutPath])
    
    of dpkInstag:
        # Check for Instag API key
        let instagKey = conf.providerConfig.instagApiKey.strip
        if instagKey.len == 0:
            return rz.err[seq[string]]("Instag API key not configured. Set it with: gld config --provider instag --apikey <key>")
        
        # Use Instag provider
        echo "⏳ Submitting to Instag (this may take a moment)..."
        
        try:
            let downloadedFiles = await providers.instagDownload(
                apiKey = instagKey,
                url = url,
                dlDir = outDir,
                maxPolls = 300,
                pollIntervalMs = 5000
            )
            
            # If user specified a specific file path (not directory), rename the first file
            if outPath.isSome:
                let theOutPath = outPath.get
                if not dirExists(theOutPath) and not theOutPath.endsWith("/") and not theOutPath.endsWith("\\"):
                    # It's a file path - rename the first downloaded file
                    if downloadedFiles.len > 0:
                        let firstFile = downloadedFiles[0]
                        try:
                            moveFile(firstFile, theOutPath)
                            return rz.ok(@[theOutPath])
                        except CatchableError as e:
                            return rz.err[seq[string]](&"Downloaded but failed to rename: {e.msg}")
            
            return rz.ok(downloadedFiles)
        except CatchableError as e:
            return rz.err[seq[string]]("Instag download failed: " & e.msg)
    
    of dpkCustom:
        return rz.err[seq[string]]("Custom provider not yet implemented")


# Legacy executeDownload for backward compatibility
proc executeDownload*(
    apiKey: string
    ,url: string
    ,platform: string
    ,outPath: Option[string]
    ,conf: GldConfig
    ,format: Option[string] = none(string)
    ,quality: Option[string] = none(string)
    ,debug: bool = false
): Future[rz.Rz[string]] {.async.} =
    ## Legacy execute download - uses LateDev provider
    let result = await executeDownloadWithProvider(
        conf, url, platform, dpkLateDev, outPath, format, quality, debug
    )
    
    result.isErr:
        return rz.err[string](result.err)
    
    if result.val.len > 0:
        return rz.ok(result.val[0])
    else:
        return rz.err[string]("No files downloaded")


# --------------------------------------------
# Main entry point
# --------------------------------------------

proc runDownload*(args: seq[string]) =
    ## Download command entry point
    
    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        printDownloadHelp()
        return
    
    let debug = hasFlag(args, "--debug")
    
    let conf = loadConfig()
    let apiKey = requireApiKey(conf)
    
    # Get URL
    var urlOpt = getPositionalUrl(args)
    
    # Also check for --url flag
    let urlFlag = pickArg(args, "--url")
    if urlFlag.isSome:
        urlOpt = urlFlag
    
    if urlOpt.isNone:
        echo "❌ No URL provided"
        echo ""
        printDownloadHelp()
        return
    
    let url = urlOpt.get
    
    # Detect or get platform
    var platformOpt: Option[string]
    
    let platformArg = pickArg(args, "--platform")
    if platformArg.isSome:
        platformOpt = normalizePlatform(platformArg.get)
        if platformOpt.isNone:
            echo &"❌ Unknown platform: {platformArg.get}"
            echo "Supported: youtube, instagram, tiktok, twitter, facebook, linkedin, bluesky"
            return
    else:
        platformOpt = detectPlatform(url)
    
    if platformOpt.isNone:
        echo "❌ Could not auto-detect platform from URL"
        echo &"URL: {url}"
        echo "Please specify platform with --platform <platform>"
        echo "Supported: youtube, instagram, tiktok, twitter, facebook, linkedin, bluesky"
        return
    
    let platform = platformOpt.get
    echo &"📥 Detected platform: {platform}"
    
    # Get provider (from CLI arg or config)
    let providerArg = pickArg(args, "--provider")
    let provider = detectProvider(providerArg, conf, platform)
    
    # Warn about Twitter + LateDev combination
    if platform == "twitter" and provider == dpkLateDev:
        echo "⚠️  Warning: LateDev's API doesn't work well for Twitter/X."
        echo "   Consider using: gld download <url> --provider instag"
        echo ""
    
    # Get output path
    var outPath = pickArg(args, "--out")
    if outPath.isNone:
        outPath = pickArg(args, "-o")
    
    if outPath.isSome:
        echo &"📁 Output: {outPath.get}"
    
    # Get format and quality options (for YouTube)
    let formatOpt = pickArg(args, "--format")
    let qualityOpt = pickArg(args, "--quality")
    
    if formatOpt.isSome:
        echo &"🎬 Requested format: {formatOpt.get}"
    if qualityOpt.isSome:
        echo &"📐 Requested quality: {qualityOpt.get}"
    
    # Execute download
    let result = waitFor executeDownloadWithProvider(
        conf, url, platform, provider, outPath, 
        formatOpt, qualityOpt, debug
    )
    
    result.isErr:
        echo &"❌ Download failed: {result.err}"
        return
    
    # Success - show downloaded files
    if result.val.len == 1:
        echo &"✅ Downloaded successfully: {result.val[0]}"
    else:
        echo &"✅ Downloaded {result.val.len} files:"
        for i, file in result.val:
            echo &"   {i+1}. {file}"


# --------------------------------------------
# Interactive download flow
# --------------------------------------------

proc interactiveDownload*(conf: GldConfig) =
    ## Interactive download flow
    let apiKey = requireApiKey(conf)
    
    echo ""
    echo "📥 Download Media from Social Platforms"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Get URL
    let url = termuiAsk("Enter URL to download:").strip
    
    if url.len == 0:
        echo "❌ No URL entered"
        return
    
    # Detect platform
    var platformOpt = detectPlatform(url)
    
    # Confirm or select platform
    if platformOpt.isSome:
        let detected = platformOpt.get
        if not termuiConfirm(&"Detected platform: {detected}. Is this correct?"):
            platformOpt = none(string)
    
    if platformOpt.isNone:
        let platforms = @[
            "youtube"
            ,"instagram"
            ,"tiktok"
            ,"twitter"
            ,"facebook"
            ,"linkedin"
            ,"bluesky"
        ]
        
        let selected = termuiSelect("Select platform:", platforms)
        platformOpt = some(selected)
    
    let platform = platformOpt.get
    
    # Get provider for this platform
    let provider = getProviderForPlatform(conf, platform)
    echo &"🔌 Provider: {$provider}"
    
    # Warn about Twitter + LateDev
    if platform == "twitter" and provider == dpkLateDev:
        if termuiConfirm("⚠️  LateDev's API doesn't work well for Twitter. Use Instag instead?"):
            if conf.providerConfig.instagApiKey.strip.len > 0:
                echo "   Switching to Instag provider"
            else:
                echo "   Instag API key not configured. Please run: gld config --provider instag --apikey <key>"
    
    # Get format/quality for YouTube
    var formatOpt: Option[string] = none(string)
    var qualityOpt: Option[string] = none(string)
    
    if platform == "youtube":
        echo ""
        echo "YouTube Options:"
        let fmt = termuiAsk("Format (mp4/webm, press Enter for default):").strip
        if fmt.len > 0:
            formatOpt = some(fmt)
        let ql = termuiAsk("Quality (360p/480p/720p/1080p, press Enter for default):").strip
        if ql.len > 0:
            qualityOpt = some(ql)
    
    # Show default download location
    let downloadDir = getDownloadDir(conf)
    echo ""
    echo &"📁 Default download location: {downloadDir}"
    echo ""
    
    # Get output path (optional)
    let outPath = termuiAsk("Output path (optional, press Enter to save in above directory):").strip
    
    let outOpt = if outPath.len > 0: some(outPath) else: none(string)
    
    # Confirm
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo &"Platform: {platform}"
    echo &"Provider: {$provider}"
    echo &"URL: {url}"
    if formatOpt.isSome:
        echo &"Format: {formatOpt.get}"
    if qualityOpt.isSome:
        echo &"Quality: {qualityOpt.get}"
    if outOpt.isSome:
        echo &"Output: {outOpt.get}"
    else:
        let autoPath = generateOutputPath(url, platform, conf)
        echo &"Output: {autoPath} (auto-generated)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if not termuiConfirm("Download?"):
        echo "Cancelled."
        return
    
    # Execute
    let result = waitFor executeDownloadWithProvider(
        conf, url, platform, provider, outOpt, formatOpt, qualityOpt
    )
    
    result.isErr:
        echo &"❌ Download failed: {result.err}"
        return
    
    if result.val.len == 1:
        echo &"✅ Downloaded successfully: {result.val[0]}"
    else:
        echo &"✅ Downloaded {result.val.len} files:"
        for i, file in result.val:
            echo &"   {i+1}. {file}"
