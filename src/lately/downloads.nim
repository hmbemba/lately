## downloads.nim - Late API (Tools: Downloads)
##
## Docs:
##   https://docs.getlate.dev/tools/downloads

# -----------------------------
# Imports
# -----------------------------
import
    std / [
        strformat
        , strutils
        , uri
        , asyncdispatch
        , httpclient
        , json
        , os
    ]

import
    rz
    ,ic


# -----------------------------
# Fallback base endpoint
# -----------------------------
when not declared(base_endpoint):
    proc base_url()      : string = "https://getlate.dev/api"
    proc api_version()   : string = "v1"
    proc base_endpoint() : string = fmt"{base_url()}/{api_version()}"


# -----------------------------
# Internal helpers
# -----------------------------
proc mk_auth_headers(
    api_key              : string
) : HttpHeaders =
    newHttpHeaders(@[
        ("Authorization", "Bearer " & api_key)
    ])


proc enc_q(
    s                    : string
) : string =
    ## URL-encode a query value
    encodeUrl(s)


proc add_q(
    url                  : var string
    ,k                   : string
    ,v                   : string
) =
    if v.len == 0: return
    if url.contains("?"):
        url.add "&" & k & "=" & enc_q(v)
    else:
        url.add "?" & k & "=" & enc_q(v)


proc downloadFileFromUrl*(
    downloadUrl          : string
    ,outFilePath         : string
) : Future[rz.Rz[string]] {.async.} =
    ## Download a file from a URL to a local path
    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 10)
    try:
        await async_client.downloadFile(downloadUrl, outFilePath)
        return rz.ok(outFilePath)
    except CatchableError as e:
        return rz.err[string]("Download failed: " & $e.msg)
    finally:
        async_client.close()


# -----------------------------
# YouTube download
# -----------------------------
discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/youtube/download
"""
proc youtubeDownloadRaw*(
    api_key              : string
    ,url                 : string
    ,action              = ""
    ,format              = ""
    ,quality             = ""
    ,formatId            = ""
) : Future[string] {.async.} = # json_string

    var
        endpoint     = fmt"{base_endpoint()}/tools/youtube/download"
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    endpoint.add_q("url", url)
    endpoint.add_q("action", action)
    endpoint.add_q("format", format)
    endpoint.add_q("quality", quality)
    endpoint.add_q("formatId", formatId)

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp      = await async_client.request(
                url         = endpoint
                ,httpMethod = HttpGet
            )
            resp_body = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/youtube/download
"""
proc youtubeDownload*(
    api_key              : string
    ,url                 : string
    ,action              = ""
    ,format              = ""
    ,quality             = ""
    ,formatId            = ""
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await youtubeDownloadRaw(
            api_key      = api_key
            ,url         = url
            ,action      = action
            ,format      = format
            ,quality     = quality
            ,formatId    = formatId
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


proc youtubeDownloadTo*(
    api_key              : string
    ,url                 : string
    ,outFilePath         : string
    ,action              = ""
    ,format              = ""
    ,quality             = ""
    ,formatId            = ""
) : Future[rz.Rz[string]] {.async.} =

    let resp = await youtubeDownload(
        api_key      = api_key
        ,url         = url
        ,action      = action
        ,format      = format
        ,quality     = quality
        ,formatId    = formatId
    )

    resp.isErr:
        return resp

    try:
        let
            json_resp   = parseJson(resp.val)
            downloadUrl = json_resp{"downloadUrl"}.getStr()

        if downloadUrl.len == 0:
            return rz.err[string] "No download URL in response"

        let dlResult = await downloadFileFromUrl(downloadUrl, outFilePath)
        dlResult.isErr:
            return dlResult
        return rz.ok outFilePath
    except CatchableError as e:
        return rz.err[string] $e.msg


# -----------------------------
# Instagram download
# -----------------------------
discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/instagram/download
"""
proc instagramDownloadRaw*(
    api_key              : string
    ,url                 : string
) : Future[string] {.async.} = # json_string

    var
        endpoint     = fmt"{base_endpoint()}/tools/instagram/download"
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    endpoint.add_q("url", url)

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp      = await async_client.request(
                url         = endpoint
                ,httpMethod = HttpGet
            )
            resp_body = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """

https://docs.getlate.dev/tools/downloads

GET /v1/tools/instagram/download
"""
proc instagramDownload*(
    api_key              : string
    ,url                 : string
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await instagramDownloadRaw(
            api_key      = api_key
            ,url         = url
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


proc instagramDownloadTo*(
    api_key              : string
    ,url                 : string
    ,outFilePath         : string
) : Future[rz.Rz[string]] {.async.} =

    let resp = await instagramDownload(
        api_key      = api_key
        ,url         = url
    )

    resp.isErr:
        return resp

    try:
        let
            json_resp   = parseJson(resp.val)
            downloadUrl = json_resp{"downloadUrl"}.getStr()

        if downloadUrl.len == 0:
            return rz.err[string] "No download URL in response"

        let dlResult = await downloadFileFromUrl(downloadUrl, outFilePath)
        dlResult.isErr:
            return dlResult
        return rz.ok outFilePath
    except CatchableError as e:
        return rz.err[string] $e.msg


# -----------------------------
# TikTok download
# -----------------------------
discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/tiktok/download
"""
proc tiktokDownloadRaw*(
    api_key              : string
    ,url                 : string
    ,action              = ""
    ,formatId            = ""
) : Future[string] {.async.} = # json_string

    var
        endpoint     = fmt"{base_endpoint()}/tools/tiktok/download"
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    endpoint.add_q("url", url)
    endpoint.add_q("action", action)
    endpoint.add_q("formatId", formatId)

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp      = await async_client.request(
                url         = endpoint
                ,httpMethod = HttpGet
            )
            resp_body = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/tiktok/download
"""
proc tiktokDownload*(
    api_key              : string
    ,url                 : string
    ,action              = ""
    ,formatId            = ""
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await tiktokDownloadRaw(
            api_key      = api_key
            ,url         = url
            ,action      = action
            ,formatId    = formatId
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


proc tiktokDownloadTo*(
    api_key              : string
    ,url                 : string
    ,outFilePath         : string
    ,action              = ""
    ,formatId            = ""
) : Future[rz.Rz[string]] {.async.} =

    let resp = await tiktokDownload(
        api_key      = api_key
        ,url         = url
        ,action      = action
        ,formatId    = formatId
    )

    resp.isErr:
        return resp

    try:
        let
            json_resp   = parseJson(resp.val)
            downloadUrl = json_resp{"downloadUrl"}.getStr()

        if downloadUrl.len == 0:
            return rz.err[string] "No download URL in response"

        let dlResult = await downloadFileFromUrl(downloadUrl, outFilePath)
        dlResult.isErr:
            return dlResult
        return rz.ok outFilePath
    except CatchableError as e:
        return rz.err[string] $e.msg


# -----------------------------
# Twitter/X download
# -----------------------------
discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/twitter/download
"""
proc twitterDownloadRaw*(
    api_key              : string
    ,url                 : string
    ,action              = ""
    ,formatId            = ""
) : Future[string] {.async.} = # json_string

    var
        endpoint     = fmt"{base_endpoint()}/tools/twitter/download"
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    endpoint.add_q("url", url)
    endpoint.add_q("action", action)
    endpoint.add_q("formatId", formatId)

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp      = await async_client.request(
                url         = endpoint
                ,httpMethod = HttpGet
            )
            resp_body = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/twitter/download
"""
proc twitterDownload*(
    api_key              : string
    ,url                 : string
    ,action              = ""
    ,formatId            = ""
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await twitterDownloadRaw(
            api_key      = api_key
            ,url         = url
            ,action      = action
            ,formatId    = formatId
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


proc twitterDownloadTo*(
    api_key              : string
    ,url                 : string
    ,outFilePath         : string
    ,action              = ""
    ,formatId            = ""
) : Future[rz.Rz[string]] {.async.} =

    let resp = await twitterDownload(
        api_key      = api_key
        ,url         = url
        ,action      = action
        ,formatId    = formatId
    )

    resp.isErr:
        return resp

    try:
        let
            json_resp   = parseJson(resp.val)
            downloadUrl = json_resp{"downloadUrl"}.getStr()

        if downloadUrl.len == 0:
            return rz.err[string] "No download URL in response"

        let dlResult = await downloadFileFromUrl(downloadUrl, outFilePath)
        dlResult.isErr:
            return dlResult
        return rz.ok outFilePath
    except CatchableError as e:
        return rz.err[string] $e.msg


# -----------------------------
# Facebook download
# -----------------------------
discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/facebook/download
"""
proc facebookDownloadRaw*(
    api_key              : string
    ,url                 : string
) : Future[string] {.async.} = # json_string

    var
        endpoint     = fmt"{base_endpoint()}/tools/facebook/download"
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    endpoint.add_q("url", url)

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp      = await async_client.request(
                url         = endpoint
                ,httpMethod = HttpGet
            )
            resp_body = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/facebook/download
"""
proc facebookDownload*(
    api_key              : string
    ,url                 : string
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await facebookDownloadRaw(
            api_key      = api_key
            ,url         = url
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


proc facebookDownloadTo*(
    api_key              : string
    ,url                 : string
    ,outFilePath         : string
) : Future[rz.Rz[string]] {.async.} =

    let resp = await facebookDownload(
        api_key      = api_key
        ,url         = url
    )

    resp.isErr:
        return resp

    try:
        let
            json_resp   = parseJson(resp.val)
            downloadUrl = json_resp{"downloadUrl"}.getStr()

        if downloadUrl.len == 0:
            return rz.err[string] "No download URL in response"

        let dlResult = await downloadFileFromUrl(downloadUrl, outFilePath)
        dlResult.isErr:
            return dlResult
        return rz.ok outFilePath
    except CatchableError as e:
        return rz.err[string] $e.msg


# -----------------------------
# LinkedIn download
# -----------------------------
discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/linkedin/download
"""
proc linkedinDownloadRaw*(
    api_key              : string
    ,url                 : string
) : Future[string] {.async.} = # json_string

    var
        endpoint     = fmt"{base_endpoint()}/tools/linkedin/download"
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    endpoint.add_q("url", url)

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp      = await async_client.request(
                url         = endpoint
                ,httpMethod = HttpGet
            )
            resp_body = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/linkedin/download
"""
proc linkedinDownload*(
    api_key              : string
    ,url                 : string
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await linkedinDownloadRaw(
            api_key      = api_key
            ,url         = url
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


proc linkedinDownloadTo*(
    api_key              : string
    ,url                 : string
    ,outFilePath         : string
) : Future[rz.Rz[string]] {.async.} =

    let resp = await linkedinDownload(
        api_key      = api_key
        ,url         = url
    )

    resp.isErr:
        return resp

    try:
        let
            json_resp   = parseJson(resp.val)
            downloadUrl = json_resp{"downloadUrl"}.getStr()

        if downloadUrl.len == 0:
            return rz.err[string] "No download URL in response"

        let dlResult = await downloadFileFromUrl(downloadUrl, outFilePath)
        dlResult.isErr:
            return dlResult
        return rz.ok outFilePath
    except CatchableError as e:
        return rz.err[string] $e.msg


# -----------------------------
# Bluesky download
# -----------------------------
discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/bluesky/download
"""
proc blueskyDownloadRaw*(
    api_key              : string
    ,url                 : string
) : Future[string] {.async.} = # json_string

    var
        endpoint     = fmt"{base_endpoint()}/tools/bluesky/download"
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    endpoint.add_q("url", url)

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp      = await async_client.request(
                url         = endpoint
                ,httpMethod = HttpGet
            )
            resp_body = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/tools/downloads
GET /v1/tools/bluesky/download
"""
proc blueskyDownload*(
    api_key              : string
    ,url                 : string
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await blueskyDownloadRaw(
            api_key      = api_key
            ,url         = url
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


proc blueskyDownloadTo*(
    api_key              : string
    ,url                 : string
    ,outFilePath         : string
) : Future[rz.Rz[string]] {.async.} =

    let resp = await blueskyDownload(
        api_key      = api_key
        ,url         = url
    )

    resp.isErr:
        return resp

    try:
        let
            json_resp   = parseJson(resp.val)
            downloadUrl = json_resp{"downloadUrl"}.getStr()

        if downloadUrl.len == 0:
            return rz.err[string] "No download URL in response"

        let dlResult = await downloadFileFromUrl(downloadUrl, outFilePath)
        dlResult.isErr:
            return dlResult
        return rz.ok outFilePath
    except CatchableError as e:
        return rz.err[string] $e.msg