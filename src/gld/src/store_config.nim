import
    std / [
        os
        ,strutils
        ,options
    ]

import
    ic
    ,jsony
    ,mynimlib/utils

import
    ./paths
    ,./types


proc defaultConfig*() : GldConfig =
    result = GldConfig(
        apiKey    : ""
        ,profileId : none string
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
    except CatchableError as e:
        icr "Failed to parse config. Using defaults.", e.msg
        result = defaultConfig()


proc saveConfig*(conf: GldConfig) =
    let 
        p   = configPath()
        raw = conf.toJson()
    #p > raw
    writeFile(p, raw)


proc requireApiKey*(conf: GldConfig) : string =
    if conf.apiKey.strip.len == 0:
        raise newException(ValueError, "Missing API key. Run: gld init")
    result = conf.apiKey
