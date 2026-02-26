## download_providers.nim - Download Provider System
##
## Provider-based download system for GLD CLI
## Supports multiple download providers (LateDev in-house, Instag, etc.)
#
## Providers can be specified per-platform or globally
## Default provider is LateDev for all platforms

import
    std / [
        strformat
        , strutils
        , uri
        , options
        , sequtils
        , json
        , asyncdispatch
        , httpclient
        , os
        , times
    ]

import
    jsony

import
    rz
    , ic

# -----------------------------
# Provider Types
# -----------------------------

type
    DownloadProviderKind* = enum
        dpkLateDev      ## Late.dev in-house API (default)
        dpkInstag       ## Instag.com API
        dpkCustom       ## Custom provider (future extensibility)

    ProviderConfig* = object
        ## Global provider configuration
        defaultProvider*: DownloadProviderKind    ## Default provider for all platforms
        lateDevApiKey*: string                    ## Late.dev API key (from main config)
        instagApiKey*: string                     ## Instag.com API key
        ## Per-platform provider overrides (empty = use default)
        platformProviders*: seq[PlatformProviderOverride]
    
    DownloadProviderConfig {.deprecated.} = ProviderConfig  ## Deprecated alias

    PlatformProviderOverride* = object
        platform*: string                         ## Platform name (twitter, instagram, etc.)
        provider*: DownloadProviderKind           ## Provider to use for this platform

    DownloadResult* = object
        ## Result of a download operation
        filePath*: string
        platform*: string
        provider*: DownloadProviderKind
        originalUrl*: string

    InstagResult* = object
        `type`*: string
        url*: string

    InstagFetchResultsResponse* = object
        results*: seq[InstagResult]

# -----------------------------
# Provider String Conversions
# -----------------------------

proc `$`*(provider: DownloadProviderKind): string =
    case provider
    of dpkLateDev: "latedev"
    of dpkInstag: "instag"
    of dpkCustom: "custom"

proc parseDownloadProviderKind*(s: string): Option[DownloadProviderKind] =
    ## Parse provider kind from string
    let lower = s.toLowerAscii.strip
    case lower
    of "latedev", "late", "late.dev": return some(dpkLateDev)
    of "instag", "instag.com": return some(dpkInstag)
    of "custom": return some(dpkCustom)
    else: return none(DownloadProviderKind)

proc defaultProviderConfig*(): ProviderConfig =
    ## Returns default provider configuration
    ProviderConfig(
        defaultProvider: dpkLateDev,
        lateDevApiKey: "",
        instagApiKey: "",
        platformProviders: @[]
    )

proc getProviderForPlatform*(
    config: ProviderConfig
    , platform: string
): DownloadProviderKind =
    ## Get the provider to use for a specific platform
    ## Returns per-platform override if set, otherwise default provider
    let lowerPlatform = platform.toLowerAscii
    
    for override in config.platformProviders:
        if override.platform.toLowerAscii == lowerPlatform:
            return override.provider
    
    return config.defaultProvider

proc setPlatformProvider*(
    config: var ProviderConfig
    , platform: string
    , provider: DownloadProviderKind
) =
    ## Set a provider for a specific platform
    let lowerPlatform = platform.toLowerAscii
    
    # Remove existing override for this platform
    config.platformProviders = config.platformProviders.filterIt(
        it.platform.toLowerAscii != lowerPlatform
    )
    
    # Add new override
    config.platformProviders.add(PlatformProviderOverride(
        platform: lowerPlatform,
        provider: provider
    ))

# -----------------------------
# LateDev Provider (Original Implementation)
# -----------------------------

proc lateDevBaseEndpoint*(): string = "https://getlate.dev/api/v1"

proc mkAuthHeaders(apiKey: string): HttpHeaders =
    newHttpHeaders(@[("Authorization", "Bearer " & apiKey)])

proc addQueryParam(url: var string, key, value: string) =
    if value.len == 0: return
    let sep = if url.contains("?"): "&" else: "?"
    url.add &"{sep}{key}={encodeUrl(value)}"

proc downloadFromUrl*(downloadUrl, outFilePath: string): Future[rz.Rz[string]] {.async.} =
    ## Download a file from a URL to a local path
    var client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 10)
    try:
        await client.downloadFile(downloadUrl, outFilePath)
        return rz.ok(outFilePath)
    except CatchableError as e:
        return rz.err[string]("Download failed: " & $e.msg)
    finally:
        client.close()

proc lateDevDownload*(
    apiKey: string
    , platform: string
    , url: string
    , format: string = ""
    , quality: string = ""
): Future[rz.Rz[string]] {.async.} =
    ## Download using Late.dev in-house API
    ## Returns JSON response with downloadUrl
    
    let endpointBase = lateDevBaseEndpoint()
    var endpoint = fmt"{endpointBase}/tools/{platform}/download"
    
    # Add query parameters
    endpoint.addQueryParam("url", url)
    if format.len > 0: endpoint.addQueryParam("format", format)
    if quality.len > 0: endpoint.addQueryParam("quality", quality)
    
    var client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    client.headers = mkAuthHeaders(apiKey)
    
    try:
        let resp = await client.request(url = endpoint, httpMethod = HttpGet)
        let body = await resp.body
        
        if resp.status[0] != '2':  # Check for 2xx status
            return rz.err[string](&"API error: {resp.status}\n{body}")
        
        return rz.ok(body)
    except CatchableError as e:
        return rz.err[string]("API request failed: " & $e.msg)
    finally:
        client.close()

proc lateDevExtractDownloadUrl*(jsonResponse: string): rz.Rz[string] =
    ## Extract download URL from Late.dev API response
    try:
        let json = parseJson(jsonResponse)
        let downloadUrl = json{"downloadUrl"}.getStr("")
        
        if downloadUrl.len == 0:
            return rz.err[string]("No downloadUrl in response")
        
        return rz.ok(downloadUrl)
    except CatchableError as e:
        return rz.err[string]("Failed to parse response: " & $e.msg)

# -----------------------------
# Instag Provider
# -----------------------------

proc instagSubmitUrl*(apiKey, url: string): Future[rz.Rz[string]] {.async.} =
    ## Submit URL to Instag API and get UUID
    var client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)
    let headers = newHttpHeaders(@[
        ("Authorization", apiKey),
        ("Content-Type", "application/x-www-form-urlencoded")
    ])
    
    try:
        let resp = await client.request(
            url = "https://instag.com/api/v1/submit/",
            body = &"url={encodeUrl(url)}",
            httpMethod = HttpPost,
            headers = headers
        )
        let body = await resp.body
        
        if resp.status[0] != '2':  # Check for 2xx status
            return rz.err[string](&"Instag submit error: {resp.status}\n{body}")
        
        # Parse JSON response
        try:
            let jsonBody = parseJson(body)
            if not jsonBody.hasKey("uuid"):
                return rz.err[string]("Response missing 'uuid' field")
            return rz.ok(jsonBody["uuid"].getStr())
        except CatchableError as e:
            return rz.err[string](&"Failed to parse UUID response: {e.msg}\nBody: {body}")
    except CatchableError as e:
        return rz.err[string]("Instag submit request failed: " & $e.msg)
    finally:
        client.close()

proc instagFetchResults*(apiKey, uuid: string): Future[rz.Rz[InstagFetchResultsResponse]] {.async.} =
    ## Fetch results from Instag API using UUID
    var client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)
    let headers = newHttpHeaders(@[
        ("Authorization", apiKey),
        ("Content-Type", "application/x-www-form-urlencoded")
    ])
    
    try:
        let resp = await client.request(
            url = "https://instag.com/api/v1/results/",
            body = &"uuid={encodeUrl(uuid)}",
            httpMethod = HttpPost,
            headers = headers
        )
        let body = await resp.body
        
        if resp.status[0] != '2':  # Check for 2xx status
            return rz.err[InstagFetchResultsResponse](&"Instag results error: {resp.status}\n{body}")
        
        # Parse JSON response
        try:
            let parsedResult = body.fromJson(InstagFetchResultsResponse)
            return rz.ok(parsedResult)
        except CatchableError as e:
            return rz.err[InstagFetchResultsResponse](&"Failed to parse results: {e.msg}\nBody: {body}")
    except CatchableError as e:
        return rz.err[InstagFetchResultsResponse]("Instag results request failed: " & $e.msg)
    finally:
        client.close()

proc instagDownload*(
    apiKey: string
    , url: string
    , dlDir: string
    , maxPolls: int = 300
    , pollIntervalMs: int = 5000
): Future[seq[string]] {.async.} =
    ## Download media using Instag API
    ## Returns sequence of downloaded file paths
    ## Raises IOError on failure
    
    # Create output directory if needed
    if not dirExists(dlDir):
        createDir(dlDir)
    
    # Submit URL and get UUID
    let uuidResult = await instagSubmitUrl(apiKey, url)
    if not uuidResult.ok:
        raise newException(IOError, "Failed to submit URL: " & uuidResult.err)
    
    let uuid = uuidResult.val
    
    # Poll for results
    var finalResults: seq[InstagResult]
    var pollCount = 0
    
    while pollCount < maxPolls:
        let results = await instagFetchResults(apiKey, uuid)
        
        if not results.ok:
            raise newException(IOError, "Failed to fetch results: " & results.err)
        
        if results.val.results.len > 0:
            finalResults = results.val.results
            break
        
        await sleepAsync(pollIntervalMs)
        pollCount.inc
    
    if finalResults.len == 0:
        raise newException(IOError, "Timeout waiting for Instag results")
    
    # Download files
    var client = newHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)
    var downloadedFiles: seq[string] = @[]
    
    try:
        for i, result in finalResults:
            # Determine file extension based on type
            let fileExt = case result.`type`
                of "video": ".mp4"
                of "image": ".jpg"
                else: ""
            
            # Generate filename
            let timestamp = now().toTime.toUnix
            let filename = dlDir / &"{timestamp}__{i}__{result.`type`}__instag{fileExt}"
            
            try:
                client.downloadFile(url = result.url, filename = filename)
                downloadedFiles.add(filename)
            except CatchableError as e:
                raise newException(IOError, "Failed to download file " & $i & ": " & e.msg)
    finally:
        client.close()
    
    return downloadedFiles

# -----------------------------
# Generic Download Interface
# -----------------------------

proc downloadWithProvider*(
    provider: DownloadProviderKind
    , providerConfig: ProviderConfig
    , platform: string
    , url: string
    , outDir: string
    , format: string = ""
    , quality: string = ""
    , debug: bool = false
): Future[rz.Rz[seq[DownloadResult]]] {.async.} =
    ## Download media using the specified provider
    ## Returns sequence of download results
    
    case provider
    of dpkLateDev:
        # Use Late.dev API
        let apiResult = await lateDevDownload(
            providerConfig.lateDevApiKey,
            platform,
            url,
            format,
            quality
        )
        
        if not apiResult.ok:
            return rz.err[seq[DownloadResult]]("LateDev API error: " & apiResult.err)
        
        if debug:
            echo "━━━ LateDev API Response ━━━"
            echo apiResult.val
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Extract download URL
        let downloadUrl = lateDevExtractDownloadUrl(apiResult.val)
        if not downloadUrl.ok:
            return rz.err[seq[DownloadResult]]("Failed to extract download URL: " & downloadUrl.err)
        
        # Generate output filename
        let timestamp = now().toTime.toUnix
        let ext = if format.len > 0: &".{format}" else: ".mp4"
        let outPath = outDir / &"{platform}_{timestamp}_latedev{ext}"
        
        # Download the file
        let dlResult = await downloadFromUrl(downloadUrl.val, outPath)
        if dlResult.err.len > 0:
            return rz.err[seq[DownloadResult]]("Download failed: " & dlResult.err)
        
        return rz.ok(@[DownloadResult(
            filePath: outPath,
            platform: platform,
            provider: dpkLateDev,
            originalUrl: url
        )])
    
    of dpkInstag:
        # Use Instag API
        try:
            let downloadedFiles = await instagDownload(
                providerConfig.instagApiKey,
                url,
                outDir
            )
            
            # Convert to DownloadResult sequence
            var results: seq[DownloadResult] = @[]
            for filePath in downloadedFiles:
                results.add(DownloadResult(
                    filePath: filePath,
                    platform: platform,
                    provider: dpkInstag,
                    originalUrl: url
                ))
            
            return rz.ok(results)
        except CatchableError as e:
            return rz.err[seq[DownloadResult]]("Instag error: " & e.msg)
    
    of dpkCustom:
        return rz.err[seq[DownloadResult]]("Custom provider not yet implemented")
