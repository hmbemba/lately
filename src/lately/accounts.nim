## accounts.nim - Late API (Accounts)
##
## Docs:
##   https://docs.getlate.dev/core/accounts

# -----------------------------
# Imports
# -----------------------------
import
    std / [
        strformat
        , strutils
        , options
        , json
        , asyncdispatch
        , httpclient
        , uri
    ]

import
    rz
    ,ic
    ,jsony


# -----------------------------
# Fallback base endpoint
# -----------------------------
when not declared(base_endpoint):
    proc base_url()      : string = "https://getlate.dev/api"
    proc api_version()   : string = "v1"
    proc base_endpoint() : string = fmt"{base_url()}/{api_version()}"


# -----------------------------
# Types
# -----------------------------
type
    platform_kind* = enum
        facebook
        instagram
        linkedin
        twitter
        tiktok
        youtube
        threads
        pinterest
        reddit
        bluesky
        googlebusiness
        telegram
        snapchat


    account_profile_ref* = object
        id               * : string
        name             * : Option[string]
        slug             * : Option[string]


    social_account* = object
        id               * : string
        platform         * : platform_kind
        profileId        * : Option[account_profile_ref]
        username         * : Option[string]
        displayName      * : Option[string]
        profileUrl       * : Option[string]
        isActive         * : Option[bool]
        followersCount   * : Option[int]
        followersLastUpdated * : Option[string]


    accounts_list_resp* = object
        accounts          * : seq[social_account]
        hasAnalyticsAccess* : bool


    follower_stat_point* = object
        date              * : string
        followers         * : int


    follower_account_summary* = object
        id                * : string
        platform          * : platform_kind
        username          * : Option[string]
        currentFollowers  * : Option[int]
        growth            * : Option[int]
        growthPercentage  * : Option[float]
        dataPoints        * : Option[int]


    date_range* = object
        `from`            * : string
        `to`              * : string


    follower_stats_resp* = object
        accounts          * : seq[follower_account_summary]
        stats             * : JsonNode               ## keyed by accountId -> [ {date, followers}, ... ]
        dateRange         * : Option[date_range]
        granularity       * : Option[string]


    account_update_resp* = object
        message           * : string
        username          * : Option[string]
        displayName       * : Option[string]


    account_disconnect_resp* = object
        message           * : string


    health_summary* = object
        total             * : int
        healthy           * : int
        warning           * : int
        error             * : int
        needsReconnect    * : int


    account_health_item* = object
        accountId         * : string
        platform          * : platform_kind
        username          * : Option[string]
        status            * : string               ## "healthy" | "warning" | "error"
        canPost           * : Option[bool]
        canFetchAnalytics * : Option[bool]
        tokenValid        * : Option[bool]
        tokenExpiresAt    * : Option[string]
        needsReconnect    * : Option[bool]
        issues            * : Option[seq[string]]


    accounts_health_resp* = object
        summary           * : health_summary
        accounts          * : seq[account_health_item]


    token_status* = object
        valid             * : bool
        expiresAt         * : Option[string]
        expiresIn         * : Option[string]
        needsRefresh      * : Option[bool]


    permission_scope* = object
        scope             * : string
        granted           * : bool
        required          * : bool


    permissions_block* = object
        posting           * : Option[seq[permission_scope]]
        analytics         * : Option[seq[permission_scope]]
        optional          * : Option[seq[permission_scope]]
        canPost           * : Option[bool]
        canFetchAnalytics * : Option[bool]
        missingRequired   * : Option[seq[string]]


    account_health_detail_resp* = object
        accountId         * : string
        platform          * : platform_kind
        username          * : Option[string]
        displayName       * : Option[string]
        status            * : string
        tokenStatus       * : Option[token_status]
        permissions       * : Option[permissions_block]
        issues            * : Option[seq[string]]
        recommendations   * : Option[seq[string]]


# -----------------------------
# jsony rename hooks (_id -> id)
# -----------------------------
    linkedin_organization* = object
        urn                * : string                # urn:li:organization:123456
        name               * : string
        vanityName         * : Option[string]        # URL-friendly name
        logoUrl            * : Option[string]        # Organization logo
        localizedName      * : Option[string]        # Localized display name
    
    linkedin_organizations_resp* = object
        organizations      * : seq[linkedin_organization]
proc renameHook*(v: var account_profile_ref, fieldName: var string) =
    if fieldName == "_id": fieldName = "id"

proc renameHook*(v: var social_account, fieldName: var string) =
    if fieldName == "_id": fieldName = "id"

proc renameHook*(v: var follower_account_summary, fieldName: var string) =
    if fieldName == "_id": fieldName = "id"


# -----------------------------
# Internal helpers
# -----------------------------
proc mk_auth_headers(
    api_key              : string
    ,content_type_json   = false
) : HttpHeaders =
    var pairs : seq[(string, string)] = @[
        ("Authorization", "Bearer " & api_key)
    ]
    if content_type_json:
        pairs.add ("Content-Type", "application/json")
    result = newHttpHeaders(pairs)


proc add_query_param(url: var string, key: string, value: string, isFirst: var bool) =
    if value.len == 0:
        return
    if isFirst:
        url.add "?"
        isFirst = false
    else:
        url.add "&"
    url.add encodeUrl(key) & "=" & encodeUrl(value)


proc add_query_param_bool(url: var string, key: string, value: bool, isFirst: var bool, includeWhenFalse = false) =
    if (not value) and (not includeWhenFalse):
        return
    add_query_param(url, key, (if value: "true" else: "false"), isFirst)


# -----------------------------
# List accounts
# -----------------------------
discard """
https://docs.getlate.dev/core/accounts#list-connected-social-accounts
"""
proc listAccountsRaw*(
    api_key              : string
    ,profileId           = none string
    ,includeOverLimit    = false
) : Future[string] {.async.} =

    var
        url          = fmt"{base_endpoint()}/accounts"
        isFirst      = true
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    if profileId.isSome:
        add_query_param(url, "profileId", profileId.get, isFirst)

    add_query_param_bool(url, "includeOverLimit", includeOverLimit, isFirst, includeWhenFalse = false)

    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/accounts#list-connected-social-accounts
"""
proc listAccounts*(
    api_key              : string
    ,profileId           = none string
    ,includeOverLimit    = false
) : Future[rz.Rz[accounts_list_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await listAccountsRaw(
            api_key           = api_key
            ,profileId        = profileId
            ,includeOverLimit = includeOverLimit
        )
    except CatchableError as e:
        return rz.err[accounts_list_resp] $e.msg

    let as_obj = catch req_body.asObj(accounts_list_resp):
        return rz.err[accounts_list_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Follower stats
# -----------------------------
discard """
https://docs.getlate.dev/core/accounts#get-follower-stats-and-growth-metrics
"""
proc accountsFollowerStatsRaw*(
    api_key              : string
    ,accountIds          = none string       # comma-separated
    ,profileId           = none string
    ,fromDate            = none string       # YYYY-MM-DD
    ,toDate              = none string       # YYYY-MM-DD
    ,granularity         = none string       # "daily" | "weekly" | "monthly"
) : Future[string] {.async.} =

    var
        url          = fmt"{base_endpoint()}/accounts/follower-stats"
        isFirst      = true
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    if accountIds.isSome: add_query_param(url, "accountIds", accountIds.get, isFirst)
    if profileId.isSome:  add_query_param(url, "profileId", profileId.get, isFirst)
    if fromDate.isSome:   add_query_param(url, "fromDate", fromDate.get, isFirst)
    if toDate.isSome:     add_query_param(url, "toDate", toDate.get, isFirst)
    if granularity.isSome:add_query_param(url, "granularity", granularity.get, isFirst)

    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/accounts#get-follower-stats-and-growth-metrics
"""
proc accountsFollowerStats*(
    api_key              : string
    ,accountIds          = none string
    ,profileId           = none string
    ,fromDate            = none string
    ,toDate              = none string
    ,granularity         = none string
) : Future[rz.Rz[follower_stats_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await accountsFollowerStatsRaw(
            api_key      = api_key
            ,accountIds  = accountIds
            ,profileId   = profileId
            ,fromDate    = fromDate
            ,toDate      = toDate
            ,granularity = granularity
        )
    except CatchableError as e:
        return rz.err[follower_stats_resp] $e.msg

    let as_obj = catch req_body.asObj(follower_stats_resp):
        return rz.err[follower_stats_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Disconnect account
# -----------------------------
discard """
https://docs.getlate.dev/core/accounts#disconnect-a-social-account
"""
proc disconnectAccountRaw*(
    api_key              : string
    ,accountId           : string
) : Future[string] {.async.} =

    let url = fmt"{base_endpoint()}/accounts/{accountId}"

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpDelete)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/accounts#disconnect-a-social-account
"""
proc disconnectAccount*(
    api_key              : string
    ,accountId           : string
) : Future[rz.Rz[account_disconnect_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await disconnectAccountRaw(api_key = api_key, accountId = accountId)
    except CatchableError as e:
        return rz.err[account_disconnect_resp] $e.msg

    let as_obj = catch req_body.asObj(account_disconnect_resp):
        return rz.err[account_disconnect_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Update account
# -----------------------------
discard """
https://docs.getlate.dev/core/accounts#update-a-social-account
"""
proc updateAccountRaw*(
    api_key              : string
    ,accountId           : string
    ,username            = none string
    ,displayName         = none string
) : Future[string] {.async.} =

    let url = fmt"{base_endpoint()}/accounts/{accountId}"

    var
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    var body = newJObject()

    if username.isSome:
        body["username"] = % username.get

    if displayName.isSome:
        body["displayName"] = % displayName.get

    try:
        let
            resp      = await async_client.request(
                url         = url
                ,httpMethod = HttpPut
                ,body       = $body
            )
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/accounts#update-a-social-account
"""
proc updateAccount*(
    api_key              : string
    ,accountId           : string
    ,username            = none string
    ,displayName         = none string
) : Future[rz.Rz[account_update_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await updateAccountRaw(
            api_key      = api_key
            ,accountId   = accountId
            ,username    = username
            ,displayName = displayName
        )
    except CatchableError as e:
        return rz.err[account_update_resp] $e.msg

    let as_obj = catch req_body.asObj(account_update_resp):
        return rz.err[account_update_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Accounts health (all)
# -----------------------------
discard """
https://docs.getlate.dev/core/accounts#check-health-of-all-connected-accounts
"""
proc accountsHealthRaw*(
    api_key              : string
    ,profileId           = none string
    ,platform            = none string
    ,status              = none string       # "healthy" | "warning" | "error"
) : Future[string] {.async.} =

    var
        url          = fmt"{base_endpoint()}/accounts/health"
        isFirst      = true
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    if profileId.isSome: add_query_param(url, "profileId", profileId.get, isFirst)
    if platform.isSome:  add_query_param(url, "platform", platform.get, isFirst)
    if status.isSome:    add_query_param(url, "status", status.get, isFirst)

    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/accounts#check-health-of-all-connected-accounts
"""
proc accountsHealth*(
    api_key              : string
    ,profileId           = none string
    ,platform            = none string
    ,status              = none string
) : Future[rz.Rz[accounts_health_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await accountsHealthRaw(
            api_key    = api_key
            ,profileId = profileId
            ,platform  = platform
            ,status    = status
        )
    except CatchableError as e:
        return rz.err[accounts_health_resp] $e.msg

    let as_obj = catch req_body.asObj(accounts_health_resp):
        return rz.err[accounts_health_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Account health (single)
# -----------------------------
discard """
https://docs.getlate.dev/core/accounts#check-health-of-a-specific-account
"""
proc accountHealthRaw*(
    api_key              : string
    ,accountId           : string
) : Future[string] {.async.} =

    let url = fmt"{base_endpoint()}/accounts/{accountId}/health"

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/accounts#check-health-of-a-specific-account
"""
proc accountHealth*(
    api_key              : string
    ,accountId           : string
) : Future[rz.Rz[account_health_detail_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await accountHealthRaw(api_key = api_key, accountId = accountId)
    except CatchableError as e:
        return rz.err[account_health_detail_resp] $e.msg

    let as_obj = catch req_body.asObj(account_health_detail_resp):
        return rz.err[account_health_detail_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj



# -----------------------------
# LinkedIn Organizations
# -----------------------------
discard """
https://docs.getlate.dev/linkedin-mentions#get-linkedin-organizations
List LinkedIn organizations (company pages) that the connected account can post to.
"""
proc getLinkedInOrganizationsRaw*(
    api_key              : string
    ,accountId           : string
) : Future[string] {.async.} =
    ## Get LinkedIn organizations available to the account
    let url = fmt"{base_endpoint()}/accounts/{accountId}/linkedin-organizations"

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/linkedin-mentions#get-linkedin-organizations
"""
proc getLinkedInOrganizations*(
    api_key              : string
    ,accountId           : string
) : Future[rz.Rz[linkedin_organizations_resp]] {.async.} =
    ## Get LinkedIn organizations available to the account (typed response)
    var req_body : string
    try:
        req_body = await getLinkedInOrganizationsRaw(api_key = api_key, accountId = accountId)
    except CatchableError as e:
        return rz.err[linkedin_organizations_resp] $e.msg

    let as_obj = catch req_body.asObj(linkedin_organizations_resp):
        return rz.err[linkedin_organizations_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj