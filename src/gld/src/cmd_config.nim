## cmd_config.nim - Configuration management for GLD CLI
##
## Manages provider settings and other configuration options
##
## Usage:
##   gld config                              # Show current config
##   gld config --provider <p>               # Set default provider
##   gld config --provider <p> --apikey <k>  # Set provider API key
##   gld config --provider <p> --platform <pl>  # Set provider for specific platform
##   gld config --clear-platform <pl>        # Remove platform provider override

import
    std/[
        strformat
        ,strutils
        ,sequtils
        ,options
        ,json
    ]

import
    rz
    ,termui
    ,ic

import
    types
    ,store_config
    ,paths
    ,../../lately/download_providers as providers


# --------------------------------------------
# Arg parsing helpers
# --------------------------------------------

proc pickArg(args: seq[string], key: string): Option[string] =
    ## Supports --key=value and --key value formats
    for i, a in args:
        if a.startsWith(key & "="):
            return some a.split("=", 1)[1].strip
        if a == key and i + 1 < args.len:
            return some args[i + 1].strip
    return none(string)


proc hasFlag(args: seq[string], key: string): bool =
    args.anyIt(it == key)


# --------------------------------------------
# Config display
# --------------------------------------------

proc showConfig*(conf: GldConfig) =
    ## Display current configuration
    echo ""
    echo "🔧 GLD Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo &"Config file: {configPath()}"
    echo ""
    echo "Late.dev API:"
    if conf.apiKey.len > 0:
        let masked = conf.apiKey[0 ..< min(8, conf.apiKey.len)] & "..."
        echo &"  API Key: {masked}"
    else:
        echo "  API Key: (not set - run: gld init)"
    echo ""
    echo "Profile:"
    if conf.profileId.isSome:
        echo &"  Default Profile: {conf.profileId.get}"
    else:
        echo "  Default Profile: (not set)"
    echo ""
    echo "Download Settings:"
    if conf.downloadDir.isSome:
        echo &"  Download Directory: {conf.downloadDir.get}"
    else:
        echo "  Download Directory: {default} (.gld/downloads)"
    echo ""
    echo "Download Providers:"
    echo &"  Default Provider: {$conf.providerConfig.defaultProvider}"
    
    if conf.providerConfig.instagApiKey.len > 0:
        let masked = conf.providerConfig.instagApiKey[0 ..< min(8, conf.providerConfig.instagApiKey.len)] & "..."
        echo &"  Instag API Key: {masked}"
    else:
        echo "  Instag API Key: (not set)"
    
    if conf.providerConfig.platformProviders.len > 0:
        echo ""
        echo "  Platform Overrides:"
        for override in conf.providerConfig.platformProviders:
            echo &"    {override.platform} → {$override.provider}"
    else:
        echo "  Platform Overrides: (none - all platforms use default)"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"


# --------------------------------------------
# Provider configuration
# --------------------------------------------

proc setDefaultProvider*(conf: var GldConfig, provider: DownloadProviderKind) =
    ## Set the default download provider
    conf.providerConfig.defaultProvider = provider
    echo &"✅ Default provider set to: {$provider}"


proc setProviderApiKey*(conf: var GldConfig, provider: DownloadProviderKind, apiKey: string) =
    ## Set API key for a provider
    case provider
    of dpkInstag:
        conf.providerConfig.instagApiKey = apiKey
        echo "✅ Instag API key set"
    of dpkLateDev:
        echo "⚠️  Late.dev API key is managed by 'gld init'. No change made."
    of dpkCustom:
        echo "⚠️  Custom provider not yet supported"


proc doSetPlatformProvider*(conf: var GldConfig, platform: string, provider: DownloadProviderKind) =
    ## Set provider override for a specific platform
    setPlatformProvider(conf, platform, provider)
    echo &"✅ Platform '{platform}' will now use provider: {$provider}"


proc doClearPlatformProvider*(conf: var GldConfig, platform: string) =
    ## Remove provider override for a platform
    removePlatformProvider(conf, platform)
    echo &"✅ Platform '{platform}' will now use default provider: {$conf.providerConfig.defaultProvider}"


# --------------------------------------------
# Interactive provider setup
# --------------------------------------------

proc interactiveProviderSetup*(conf: var GldConfig) =
    ## Interactive setup for download providers
    echo ""
    echo "🔧 Download Provider Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Download providers determine which service is used to download"
    echo "media from social platforms (Instagram, Twitter, etc.)."
    echo ""
    echo "Available providers:"
    echo "  • latedev - Late.dev in-house API (default, works for most)"
    echo "  • instag  - Instag.com API (better for Instagram & Twitter/X)"
    echo ""
    
    # Select default provider
    let providers = @["latedev", "instag"]
    let currentDefault = $conf.providerConfig.defaultProvider
    echo &"Current default provider: {currentDefault}"
    echo ""
    
    if termuiConfirm("Change default provider?"):
        let selected = termuiSelect("Select default provider:", providers)
        let parsed = parseDownloadProviderKind(selected)
        if parsed.isSome:
            setDefaultProvider(conf, parsed.get)
    
    # Configure Instag API key
    echo ""
    echo "Instag API Key:"
    if conf.providerConfig.instagApiKey.len > 0:
        let masked = conf.providerConfig.instagApiKey[0 ..< min(8, conf.providerConfig.instagApiKey.len)] & "..."
        echo &"  Current: {masked}"
    else:
        echo "  Current: (not set)"
    
    if termuiConfirm("Update Instag API key?"):
        let newKey = termuiAsk("Enter Instag API key:").strip
        if newKey.len > 0:
            setProviderApiKey(conf, dpkInstag, newKey)
    
    # Platform overrides
    echo ""
    echo "Platform-Specific Providers:"
    echo "  You can set different providers for different platforms."
    echo "  For example: Use Instag for Twitter, LateDev for everything else."
    echo ""
    
    let platforms = @[
        "youtube", "instagram", "tiktok", "twitter",
        "facebook", "linkedin", "bluesky"
    ]
    
    if termuiConfirm("Configure platform-specific providers?"):
        for platform in platforms:
            let currentProvider = getProviderForPlatform(conf, platform)
            echo &""
            echo &"{platform} → {$currentProvider}"
            if termuiConfirm(&"Change provider for {platform}?"):
                let provs = @["latedev", "instag", "(use default)"]
                let sel = termuiSelect("Select provider:", provs)
                if sel == "(use default)":
                    removePlatformProvider(conf, platform)
                    echo &"  Removed override for {platform}"
                else:
                    let parsed = parseDownloadProviderKind(sel)
                    if parsed.isSome:
                        doSetPlatformProvider(conf, platform, parsed.get)
    
    # Save config
    saveConfig(conf)
    echo ""
    echo "✅ Configuration saved"


# --------------------------------------------
# Main entry point
# --------------------------------------------

proc runConfig*(args: seq[string]) =
    ## Config command entry point
    
    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        echo "gld config - Manage GLD configuration"
        echo ""
        echo "Usage:"
        echo "  gld config                              Show current configuration"
        echo "  gld config --interactive                Interactive configuration wizard"
        echo "  gld config --provider <p>               Set default provider (latedev, instag)"
        echo "  gld config --provider <p> --apikey <k>  Set API key for provider"
        echo "  gld config --provider <p> --platform <pl>  Set provider for specific platform"
        echo "  gld config --clear-platform <pl>        Remove platform provider override"
        echo ""
        echo "Examples:"
        echo "  gld config --provider instag"
        echo "  gld config --provider instag --apikey abc123"
        echo "  gld config --provider instag --platform twitter"
        echo "  gld config --clear-platform twitter"
        echo ""
        return
    
    var conf = loadConfig()
    var modified = false
    
    # Interactive mode
    if hasFlag(args, "--interactive") or hasFlag(args, "-i"):
        interactiveProviderSetup(conf)
        return
    
    # Get provider argument
    let providerArg = pickArg(args, "--provider")
    let apiKeyArg = pickArg(args, "--apikey")
    let platformArg = pickArg(args, "--platform")
    let clearPlatformArg = pickArg(args, "--clear-platform")
    
    # Handle --clear-platform
    if clearPlatformArg.isSome:
        doClearPlatformProvider(conf, clearPlatformArg.get)
        modified = true
    
    # Handle --provider
    if providerArg.isSome:
        let parsed = parseDownloadProviderKind(providerArg.get)
        if parsed.isNone:
            echo &"❌ Unknown provider: {providerArg.get}"
            echo "Valid providers: latedev, instag"
            return
        
        let provider = parsed.get
        
        if platformArg.isSome:
            # Set provider for specific platform
            doSetPlatformProvider(conf, platformArg.get, provider)
            modified = true
        else:
            # Set as default provider
            setDefaultProvider(conf, provider)
            modified = true
    
    # Handle --apikey (must come with --provider)
    if apiKeyArg.isSome:
        if providerArg.isNone:
            echo "❌ --apikey requires --provider"
            echo "Example: gld config --provider instag --apikey <key>"
            return
        
        let parsed = parseDownloadProviderKind(providerArg.get)
        if parsed.isNone:
            return  # Error already shown above
        
        setProviderApiKey(conf, parsed.get, apiKeyArg.get)
        modified = true
    
    # Save if modified
    if modified:
        saveConfig(conf)
        echo ""
        echo "💾 Configuration saved to:", configPath()
    else:
        # Just show current config
        showConfig(conf)
