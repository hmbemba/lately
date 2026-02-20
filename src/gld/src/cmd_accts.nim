# src/gld/cmd_accounts.nim

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
    ../../late_dev/accounts as late_accounts
    ,store_config
    ,types


proc optStr[T](
    v                   : Option[T]
)                       : string =
    if v.isSome: $v.get else: ""


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


proc printAccountsHelp() =
    echo "gld accounts - List connected social accounts"
    echo ""
    echo "Usage:"
    echo "  gld accounts"
    echo "  gld accounts --profile <profileId>"
    echo "  gld accounts --all"
    echo "  gld accounts --raw"
    echo "  gld accounts --health"
    echo ""
    echo "Options:"
    echo "  --profile <id>   Filter by profile id (defaults to config profileId if set)"
    echo "  --all            includeOverLimit=true"
    echo "  --raw            print raw JSON response (list accounts)"
    echo "  --health         show account health summary + items"
    echo ""


proc renderAccountsTable(
    accounts             : seq[late_accounts.social_account]
) =
    if accounts.len == 0:
        echo "(no accounts)"
        return

    echo "Platform   Active   Username           Display Name        Followers   Profile"
    echo "--------   ------   ----------------   ----------------   ---------   ----------------"

    for a in accounts:
        let
            platform   = $a.platform
            activeStr  = if a.isActive.isSome: (if a.isActive.get: "yes" else: "no") else: ""
            username   = optStr(a.username)
            display    = optStr(a.displayName)
            followers  = if a.followersCount.isSome: $a.followersCount.get else: ""
            profileStr =
                if a.profileId.isSome:
                    let pr = a.profileId.get
                    if pr.name.isSome and pr.name.get.strip.len > 0:
                        pr.name.get & " (" & pr.id & ")"
                    else:
                        pr.id
                else:
                    ""

        echo fmt"{platform:<10} {activeStr:<6} {username:<16} {display:<16} {followers:<9} {profileStr}"


proc renderHealth(
    h                   : late_accounts.accounts_health_resp
) =
    echo "Health Summary:"
    echo "  total          : " & $h.summary.total
    echo "  healthy        : " & $h.summary.healthy
    echo "  warning        : " & $h.summary.warning
    echo "  error          : " & $h.summary.error
    echo "  needsReconnect : " & $h.summary.needsReconnect
    echo ""

    if h.accounts.len == 0:
        echo "(no health items)"
        return

    echo "Platform   Status    CanPost   Analytics   NeedsReconnect   Username"
    echo "--------   ------    ------    ---------   -------------    ----------------"

    for a in h.accounts:
        let
            platform = $a.platform
            status   = a.status
            canPost  = if a.canPost.isSome: (if a.canPost.get: "yes" else: "no") else: ""
            canAna   = if a.canFetchAnalytics.isSome: (if a.canFetchAnalytics.get: "yes" else: "no") else: ""
            needsRec = if a.needsReconnect.isSome: (if a.needsReconnect.get: "yes" else: "no") else: ""
            user     = optStr(a.username)

        echo fmt"{platform:<10} {status:<8} {canPost:<8} {canAna:<9} {needsRec:<13} {user}"


proc runAccounts*(args: seq[string]) =
    let 
        conf  = loadConfig()
        apiKey = requireApiKey(conf)

    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        printAccountsHelp()
        return

    if conf.apiKey.strip.len == 0:
        raise newException(ValueError, "Missing apiKey. Run: gld init")

    let
        includeOverLimit = hasFlag(args, "--all")
        rawMode          = hasFlag(args, "--raw")
        healthMode       = hasFlag(args, "--health")
        profileOverride  = pickArg(args, "--profile")

    let profileId =
        if profileOverride.isSome: some profileOverride.get
        elif conf.profileId.isSome: conf.profileId
        else: none string

    if healthMode:
        let healthRes = waitFor late_accounts.accountsHealth(
            api_key    = conf.apiKey
            ,profileId = profileId
        )

        healthRes.isErr:
            icr healthRes.err
            raise newException(ValueError, "Failed to fetch accounts health.")

        renderHealth(healthRes.val)
        return

    if rawMode:
        let raw = waitFor late_accounts.listAccountsRaw(
            api_key           = conf.apiKey
            ,profileId        = profileId
            ,includeOverLimit = includeOverLimit
        )
        echo raw
        return

    let res = waitFor late_accounts.listAccounts(
        api_key           = conf.apiKey
        ,profileId        = profileId
        ,includeOverLimit = includeOverLimit
    )

    res.isErr:
        icr res.err
        raise newException(ValueError, "Failed to list accounts.")

    renderAccountsTable(res.val.accounts)

    if res.val.hasAnalyticsAccess:
        echo ""
        echo "Analytics access: ✅"
    else:
        echo ""
        echo "Analytics access: ❌"
