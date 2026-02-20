## media.nim - Late API (Media)
##
## Docs:
##   https://docs.getlate.dev/utilities/media

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
        , os
        , mimetypes # Added mimetypes lib
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
    media_presign_req   * = object
        filename        * : string
        contentType     * : string
        size            * : Option[int]

    media_presign_resp  * = object
        uploadUrl       * : string
        publicUrl       * : string


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


proc is_http_ok(
    code                 : HttpCode
) : bool =
    let c = code.int
    result = c >= 200 and c < 300


proc raise_http_err(
    what                 : string
    ,code                : HttpCode
    ,body                : string
) =
    raise newException(
        IOError
        ,&"{what} HTTP Error ({code.int}).\nResponse -> {body}"
    )




proc file_size(
    path                 : string
) : rz.Rz[int] =
    try:
        return rz.ok getFileSize(path).int
    except CatchableError as e:
        return rz.err[int] &"Failed to stat file. path={path}\nError -> {$e.msg}"


# -----------------------------
# Get presigned upload URL
# -----------------------------
discard """
https://docs.getlate.dev/utilities/media
"""
proc mediaPresignRaw*(
    api_key              : string
    ,filename            : string
    ,contentType         : string
    ,size                = none int
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/media/presign"

    var
        async_client     = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    var body = %*{
        "filename"        : filename
        ,"contentType"    : contentType
    }

    if size.isSome:
        body["size"] = % size.get

    try:
        let
            resp          = await async_client.request(
                url         = url
                ,httpMethod = HttpPost
                ,body       = $body
            )
            resp_body     = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/utilities/media
"""
proc mediaPresign*(
    api_key              : string
    ,filename            : string
    ,contentType         : string
    ,size                = none int
) : Future[rz.Rz[media_presign_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await mediaPresignRaw(
            api_key      = api_key
            ,filename    = filename
            ,contentType = contentType
            ,size        = size
        )
    except CatchableError as e:
        return rz.err[media_presign_resp] $e.msg

    let as_obj = catch req_body.asObj(media_presign_resp):
        return rz.err[media_presign_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Convenience: Presign from a local file path
# -----------------------------
discard """
https://docs.getlate.dev/utilities/media
"""
proc mediaPresignFromFile*(
    api_key              : string
    ,file_path           : string
) : Future[rz.Rz[media_presign_resp]] {.async.} =

    let
        split_f = splitFile(file_path)
        fname   = split_f.name & split_f.ext
        
        # Auto-detect mime type
        m       = newMimetypes()
        # remove dot from extension if present for lookup
        ext     = if split_f.ext.startsWith("."): split_f.ext[1..^1] else: split_f.ext 
        cType   = m.getMimetype(ext, default = "application/octet-stream")

        fsize   = catch file_size(file_path):
            return rz.err[media_presign_resp] it.err

    return await mediaPresign(
        api_key      = api_key
        ,filename    = fname
        ,contentType = cType
        ,size        = some fsize
    )




# -----------------------------
# Upload to presigned URL (PUT)
# -----------------------------
discard """
https://docs.getlate.dev/utilities/media
Step 2: PUT file bytes to uploadUrl
"""
proc mediaUploadToPresignedUrlRaw*(
    uploadUrl            : string
    ,file_path           : string
    ,contentType         : string
) : Future[string] {.async.} = # json_string (usually empty)

    var
        async_client     = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)
        headers          = newHttpHeaders(@[
            ("Content-Type", contentType)
        ])

    let file_bytes = readFile(file_path)  # NOTE: reads whole file into memory

    try:
        let
            resp          = await async_client.request(
                url         = uploadUrl
                ,httpMethod = HttpPut
                ,headers    = headers
                ,body       = file_bytes
            )
            resp_body     = await resp.body

        if not is_http_ok(resp.code):
            raise_http_err("Late Media Upload (PUT)", resp.code, resp_body)

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/utilities/media
Step 2: PUT file bytes to uploadUrl
"""
proc mediaUploadToPresignedUrl*(
    uploadUrl            : string
    ,file_path           : string
    ,contentType         : string
) : Future[rz.Rz[string]] {.async.} =

    var req_body : string
    try:
        req_body = await mediaUploadToPresignedUrlRaw(
            uploadUrl    = uploadUrl
            ,file_path   = file_path
            ,contentType = contentType
        )
    except CatchableError as e:
        return rz.err[string] $e.msg

    return rz.ok req_body


# -----------------------------
# Convenience: Presign + Upload + Return publicUrl
# -----------------------------
discard """
https://docs.getlate.dev/utilities/media
1) POST /v1/media/presign  -> uploadUrl/publicUrl
2) PUT file bytes          -> uploadUrl
3) return publicUrl
"""
proc mediaUploadFile*(
    api_key              : string
    ,file_path           : string
) : Future[rz.Rz[string]] {.async.} =

    let 
        split_f = splitFile(file_path)
        fname   = split_f.name & split_f.ext

    var
        m        = newMimetypes()
        ext      = if split_f.ext.startsWith("."): split_f.ext[1..^1] else: split_f.ext
        cType    = m.getMimetype(ext, default = "application/octet-stream")

    let fsize = file_size(file_path)
    fsize.iserr:
        return rz.err[string] fsize.err

    let pres = await mediaPresign(
        api_key      = api_key
        ,filename    = fname
        ,contentType = cType
        ,size        = some fsize.val
    )
    pres.isErr:
        return rz.err[string] pres.err

    var
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)
        headers      = newHttpHeaders(@[
            ("Content-Type", cType)
        ])

    let file_bytes = readFile(file_path)  # reads whole file into memory

    try:
        let
            resp      = await async_client.request(
                url         = pres.val.uploadUrl
                ,httpMethod = HttpPut
                ,headers    = headers
                ,body       = file_bytes
            )
            resp_body = await resp.body

        if not (resp.code.int >= 200 and resp.code.int < 300):
            return rz.err[string] &"Late Media Upload (PUT) HTTP Error ({resp.code.int}).\nResponse -> {resp_body}"

        return rz.ok pres.val.publicUrl
    except CatchableError as e:
        return rz.err[string] $e.msg
    finally:
        async_client.close()
