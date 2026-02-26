import
    std / [
        os
        ,strutils
        ,options
        ,sequtils
    ]

import
    ic
    ,jsony
    ,mynimlib/utils

import
    ./paths
    ,./types


proc defaultProviderConfig*(): ProviderConfig =
    ## Returns default provider configuration
    ProviderConfig(
        defaultProvider: dpkLateDev,
        instagApiKey: "",
        platformProviders: @[]
    )


proc defaultConfig*() : GldConfig =
    result = GldConfig(
        apiKey      : ""
        ,profileId  : none string
        ,downloadDir: none string   # Will use .gld/downloads by default
        ,providerConfig: defaultProviderConfig()
    )


proc loadConfig*() : GldConfig =
    let p = configPath()
    if not fileExists(p):
        result = defaultConfig()
        return

    let raw = readFile(p)
    if raw.strip.len == 0:
        result = defaultConfig()
        return

    try:
        result = raw.fromJson(GldConfig)
        # Ensure providerConfig is initialized (for backward compatibility)
        if result.providerConfig.defaultProvider notin {dpkLateDev, dpkInstag, dpkCustom}:
            result.providerConfig = defaultProviderConfig()
    except CatchableError as e:
        icr "Failed to parse config. Using defaults.", e.msg
        result = defaultConfig()


proc saveConfig*(conf: GldConfig) =
    let 
        p   = configPath()
        raw = conf.toJson()
    writeFile(p, raw)


proc requireApiKey*(conf: GldConfig) : string =
    if conf.apiKey.strip.len == 0:
        raise newException(ValueError, "Missing API key. Run: gld init")
    result = conf.apiKey


proc getDownloadDir*(conf: GldConfig) : string =
    ## Get the configured download directory, or default to .gld/downloads
    if conf.downloadDir.isSome and conf.downloadDir.get.strip.len > 0:
        let customDir = conf.downloadDir.get.strip
        # Create directory if it doesn't exist
        if not dirExists(customDir):
            createDir(customDir)
        result = customDir
    else:
        result = downloadsDir()


# --------------------------------------------
# Provider Configuration Helpers
# --------------------------------------------

proc getProviderForPlatform*(conf: GldConfig, platform: string): DownloadProviderKind =
    ## Get the provider to use for a specific platform
    ## Returns per-platform override if set, otherwise default provider
    let lowerPlatform = platform.toLowerAscii
    
    for override in conf.providerConfig.platformProviders:
        if override.platform.toLowerAscii == lowerPlatform:
            return override.provider
    
    return conf.providerConfig.defaultProvider


proc setPlatformProvider*(conf: var GldConfig, platform: string, provider: DownloadProviderKind) =
    ## Set a provider for a specific platform
    let lowerPlatform = platform.toLowerAscii
    
    # Remove existing override for this platform
    conf.providerConfig.platformProviders = conf.providerConfig.platformProviders.filterIt(
        it.platform.toLowerAscii != lowerPlatform
    )
    
    # Add new override
    conf.providerConfig.platformProviders.add(PlatformProviderOverride(
        platform: lowerPlatform,
        provider: provider
    ))


proc removePlatformProvider*(conf: var GldConfig, platform: string) =
    ## Remove provider override for a specific platform
    let lowerPlatform = platform.toLowerAscii
    conf.providerConfig.platformProviders = conf.providerConfig.platformProviders.filterIt(
        it.platform.toLowerAscii != lowerPlatform
    )


proc requireInstagApiKey*(conf: GldConfig): string =
    ## Get Instag API key, raising error if not set
    let key = conf.providerConfig.instagApiKey.strip
    if key.len == 0:
        raise newException(ValueError, "Missing Instag API key. Configure with: gld config --provider instag --apikey <key>")
    result = key
