## posts.nim - Late API (Posts)
##
## Docs:
##   https://docs.getlate.dev/core/posts

# -----------------------------
# Imports
# -----------------------------
import
    std / [
        strformat
        , strutils
        , options
        , sequtils
        , json
        , asyncdispatch
        , httpclient
        , uri
    ]

import
    rz
    ,ic
    , jsony

import
    ./models


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
    post_platform_entry    * = object
        platform           * : string
        accountId          * : JsonNode
        status             * : Option[string]
        platformPostId     * : Option[string]
        platformPostUrl    * : Option[string]

    post                   * = object
        id                 * : string
        title              * : Option[string]
        content            * : Option[string]
        status             * : Option[string]
        scheduledFor       * : Option[string]
        timezone           * : Option[string]
        publishNow         * : Option[bool]
        isDraft            * : Option[bool]
        queuedFromProfile  * : Option[string]
        queueId            * : Option[string]
        tags               * : Option[seq[string]]
        hashtags           * : Option[seq[string]]
        mentions           * : Option[seq[string]]
        crosspostingEnabled* : Option[bool]
        metadata           * : Option[JsonNode]
        mediaItems         * : Option[seq[JsonNode]]
        platforms          * : Option[seq[post_platform_entry]]
        createdAt          * : Option[string]
        updatedAt          * : Option[string]
        publishedAt        * : Option[string]

    pagination             * = object
        page               * : int
        limit              * : int
        total              * : int
        pages              * : int

    posts_list_resp        * = object
        posts              * : seq[post]
        pagination         * : Option[pagination]

    post_get_resp          * = object
        post               * : post

    post_write_resp        * = object
        post               * : post
        message            * : Option[string]

    post_delete_resp       * = object
        message            * : string


    http_raw_resp * = object
        code       * : int
        status     * : string
        location   * : string
        body       * : string

proc renameHook*(
    v                      : var post
    ,fieldName             : var string
) =
    if fieldName == "_id":
        fieldName = "id"


# -----------------------------
# Internal helpers
# -----------------------------

proc mkOptionalObj[T](obj:T): JsonNode = 
    result = newJObject()
    for n,v in obj.fieldPairs:
        when v is Option:
            if v.isSome:
                when v.get is enum:
                    result[n] = % $v.get
                else:
                    result[n] = % v.get
        else:
            result[n] = % v

proc mk_auth_headers(
    api_key                : string
    ,content_type_json     = false
) : HttpHeaders =
    var pairs : seq[(string, string)] = @[
        ("Authorization", "Bearer " & api_key)
    ]
    if content_type_json:
        pairs.add ("Content-Type", "application/json")

    result = newHttpHeaders(pairs)


proc addQueryParam(
    url                    : var string
    ,key                   : string
    ,val                   : string
) =
    if val.len == 0:
        return

    if url.contains("?"):
        url.add "&"
    else:
        url.add "?"

    url.add key
    url.add "="
    url.add encodeUrl(val)


proc addQueryParam(
    url                    : var string
    ,key                   : string
    ,val                   : bool
) =
    if url.contains("?"):
        url.add "&"
    else:
        url.add "?"

    url.add key
    url.add "="
    url.add (if val: "true" else: "false")


# -----------------------------
# List posts
# -----------------------------
discard """
https://docs.getlate.dev/core/posts#list-posts-visible-to-the-authenticated-user
"""
proc listPostsRaw*(
    api_key                : string
    ,page                  = 1
    ,limit                 = 10
    ,status                = ""
    ,platform              = ""
    ,profileId             = ""
    ,createdBy             = ""
    ,dateFrom              = ""
    ,dateTo                = ""
    ,includeHidden         = false
) : Future[string] {.async.} = # json_string

    var
        url                = fmt"{base_endpoint()}/posts"
        async_client       = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    url.addQueryParam("page"         ,$page)
    url.addQueryParam("limit"        ,$limit)
    url.addQueryParam("status"       ,status)
    url.addQueryParam("platform"     ,platform)
    url.addQueryParam("profileId"    ,profileId)
    url.addQueryParam("createdBy"    ,createdBy)
    url.addQueryParam("dateFrom"     ,dateFrom)
    url.addQueryParam("dateTo"       ,dateTo)

    if includeHidden:
        url.addQueryParam("includeHidden", true)

    async_client.headers   = mk_auth_headers(
        api_key            = api_key
    )

    try:
        let
            resp           = await async_client.request(
                url         = url
                ,httpMethod = HttpGet
            )
            resp_body      = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/posts#list-posts-visible-to-the-authenticated-user
"""
proc listPosts*(
    api_key                : string
    ,page                  = 1
    ,limit                 = 10
    ,status                = ""
    ,platform              = ""
    ,profileId             = ""
    ,createdBy             = ""
    ,dateFrom              = ""
    ,dateTo                = ""
    ,includeHidden         = false
) : Future[rz.Rz[posts_list_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await listPostsRaw(
            api_key        = api_key
            ,page          = page
            ,limit         = limit
            ,status        = status
            ,platform      = platform
            ,profileId     = profileId
            ,createdBy     = createdBy
            ,dateFrom      = dateFrom
            ,dateTo        = dateTo
            ,includeHidden = includeHidden
        )
    except CatchableError as e:
        return err[posts_list_resp]($e.msg)

    let as_obj = catch req_body.asObj(posts_list_resp):
        return err[posts_list_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Create post
# -----------------------------
discard """
https://docs.getlate.dev/core/posts#create-a-draft-scheduled-or-immediate-post
"""
proc createPostRaw*(
    api_key                : string
    ,title                 = none string
    ,content               = none string
    ,mediaItems            : seq[mediaItem] = @[]
    ,platforms             : seq[platform]  = @[]
    ,scheduledFor          = none string
    ,publishNow            = none bool
    ,isDraft               = none bool
    ,timezone              = some "UTC"
    ,tags                  : seq[string] = @[]
    ,hashtags              : seq[string] = @[]
    ,mentions              : seq[string] = @[]
    ,crosspostingEnabled   = none bool
    ,metadata              = none JsonNode
    ,queuedFromProfile     = none string
    ,queueId               = none string
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/posts"

    var
        async_client       = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers   = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    var body = newJObject()

    if title.isSome:
        body["title"]              = % title.get

    if content.isSome:
        body["content"]            = % content.get

    if mediaItems.len > 0:
        body["mediaItems"]         = % mediaItems

    if platforms.len > 0:
        body["platforms"]          = % platforms.mapit(mkOptionalObj it)

    if scheduledFor.isSome:
        body["scheduledFor"]       = % scheduledFor.get

    if publishNow.isSome:
        body["publishNow"]         = % publishNow.get

    if isDraft.isSome:
        body["isDraft"]            = % isDraft.get

    if timezone.isSome:
        body["timezone"]           = % timezone.get

    if tags.len > 0:
        body["tags"]               = % tags

    if hashtags.len > 0:
        body["hashtags"]           = % hashtags

    if mentions.len > 0:
        body["mentions"]           = % mentions

    if crosspostingEnabled.isSome:
        body["crosspostingEnabled"]= % crosspostingEnabled.get

    if metadata.isSome:
        body["metadata"]           = metadata.get

    if queuedFromProfile.isSome:
        body["queuedFromProfile"]  = % queuedFromProfile.get

    if queueId.isSome:
        body["queueId"]            = % queueId.get

    try:
        let
            resp           = await async_client.request(
                url         = url
                ,httpMethod = HttpPost
                ,body       = $body
            )
            resp_body      = await resp.body

        return resp_body
    finally:
        async_client.close()



proc createPostRawResp*(
    api_key                : string
    ,title                 = none string
    ,content               = none string
    ,mediaItems            : seq[mediaItem] = @[]
    ,platforms             : seq[platform]  = @[]
    ,scheduledFor          = none string
    ,publishNow            = none bool
    ,isDraft               = none bool
    ,timezone              = some "UTC"
    ,tags                  : seq[string] = @[]
    ,hashtags              : seq[string] = @[]
    ,mentions              : seq[string] = @[]
    ,crosspostingEnabled   = none bool
    ,metadata              = none JsonNode
    ,queuedFromProfile     = none string
    ,queueId               = none string
) : Future[http_raw_resp] {.async.} =

    let url = fmt"{base_endpoint()}/posts"

    var
        async_client = newAsyncHttpClient(
            userAgent    = "gld/1.0"
            ,maxRedirects = 5
        )

    async_client.headers = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )
    async_client.headers["Accept"] = "application/json"

    var body = newJObject()

    if title.isSome:
        body["title"] = % title.get

    if content.isSome:
        body["content"] = % content.get

    if mediaItems.len > 0:
        body["mediaItems"] = % mediaItems

    if platforms.len > 0:
        body["platforms"] = % platforms.mapit(mkOptionalObj it)

    if scheduledFor.isSome:
        body["scheduledFor"] = % scheduledFor.get

    if publishNow.isSome:
        body["publishNow"] = % publishNow.get

    if isDraft.isSome:
        body["isDraft"] = % isDraft.get

    if timezone.isSome:
        body["timezone"] = % timezone.get

    if tags.len > 0:
        body["tags"] = % tags

    if hashtags.len > 0:
        body["hashtags"] = % hashtags

    if mentions.len > 0:
        body["mentions"] = % mentions

    if crosspostingEnabled.isSome:
        body["crosspostingEnabled"] = % crosspostingEnabled.get

    if metadata.isSome:
        body["metadata"] = metadata.get

    if queuedFromProfile.isSome:
        body["queuedFromProfile"] = % queuedFromProfile.get

    if queueId.isSome:
        body["queueId"] = % queueId.get

    try:
        let resp = await async_client.request(
            url         = url
            ,httpMethod = HttpPost
            ,body       = $body
        )

        result.code = resp.code.int
        result.status = resp.status
        if resp.headers.hasKey("Location"):
            result.location = resp.headers["Location"]
        result.body = await resp.body
    finally:
        async_client.close()

discard """
https://docs.getlate.dev/core/posts#create-a-draft-scheduled-or-immediate-post
"""
# proc createPost*(
#     api_key                : string
#     ,title                 = none string
#     ,content               = none string
#     ,mediaItems            : seq[mediaItem] = @[]
#     ,platforms             : seq[platform]  = @[]
#     ,scheduledFor          = none string
#     ,publishNow            = none bool
#     ,isDraft               = none bool
#     ,timezone              = some "UTC"
#     ,tags                  : seq[string] = @[]
#     ,hashtags              : seq[string] = @[]
#     ,mentions              : seq[string] = @[]
#     ,crosspostingEnabled   = none bool
#     ,metadata              = none JsonNode
#     ,queuedFromProfile     = none string
#     ,queueId               = none string
# ) : Future[rz.Rz[post_write_resp]] {.async.} =

#     var req_body : string
#     try:
#         req_body = await createPostRaw(
#             api_key              = api_key
#             ,title               = title
#             ,content             = content
#             ,mediaItems          = mediaItems
#             ,platforms           = platforms
#             ,scheduledFor        = scheduledFor
#             ,publishNow          = publishNow
#             ,isDraft             = isDraft
#             ,timezone            = timezone
#             ,tags                = tags
#             ,hashtags            = hashtags
#             ,mentions            = mentions
#             ,crosspostingEnabled = crosspostingEnabled
#             ,metadata            = metadata
#             ,queuedFromProfile   = queuedFromProfile
#             ,queueId             = queueId
#         )
#     except CatchableError as e:
#         return err[post_write_resp]($e.msg)

#     let as_obj = catch req_body.asObj(post_write_resp):
#         return err[post_write_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

#     return rz.ok as_obj


proc createPost*(
    api_key                : string
    ,title                 = none string
    ,content               = none string
    ,mediaItems            : seq[mediaItem] = @[]
    ,platforms             : seq[platform]  = @[]
    ,scheduledFor          = none string
    ,publishNow            = none bool
    ,isDraft               = none bool
    ,timezone              = some "UTC"
    ,tags                  : seq[string] = @[]
    ,hashtags              : seq[string] = @[]
    ,mentions              : seq[string] = @[]
    ,crosspostingEnabled   = none bool
    ,metadata              = none JsonNode
    ,queuedFromProfile     = none string
    ,queueId               = none string
) : Future[rz.Rz[post_write_resp]] {.async.} =

    var raw : http_raw_resp
    try:
        raw = await createPostRawResp(
            api_key              = api_key
            ,title               = title
            ,content             = content
            ,mediaItems          = mediaItems
            ,platforms           = platforms
            ,scheduledFor        = scheduledFor
            ,publishNow          = publishNow
            ,isDraft             = isDraft
            ,timezone            = timezone
            ,tags                = tags
            ,hashtags            = hashtags
            ,mentions            = mentions
            ,crosspostingEnabled = crosspostingEnabled
            ,metadata            = metadata
            ,queuedFromProfile   = queuedFromProfile
            ,queueId             = queueId
        )
    except CatchableError as e:
        return err[post_write_resp]($e.msg)

    let bodyStr = raw.body.strip

    if raw.code < 200 or raw.code >= 300:
        return err[post_write_resp](
            &"HTTP {raw.code} {raw.status}\nLocation: {raw.location}\nBody: {raw.body}"
        )

    if bodyStr.len == 0:
        return err[post_write_resp](
            &"Empty response body (HTTP {raw.code} {raw.status}). Location: {raw.location}"
        )

    let as_obj = catch bodyStr.asObj(post_write_resp):
        return err[post_write_resp](
            &"Error parsing response to object.\nHTTP: {raw.code} {raw.status}\nResponse -> {raw.body}\nParsing Error -> {it.err}"
        )

    return rz.ok as_obj



# -----------------------------
# Get post
# -----------------------------
discard """
https://docs.getlate.dev/core/posts#get-a-single-post
"""
proc getPostRaw*(
    api_key                : string
    ,postId                : string
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/posts/{postId}"

    var
        async_client       = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers   = mk_auth_headers(
        api_key            = api_key
    )

    try:
        let
            resp           = await async_client.request(
                url         = url
                ,httpMethod = HttpGet
            )
            resp_body      = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/posts#get-a-single-post
"""
proc getPost*(
    api_key                : string
    ,postId                : string
) : Future[rz.Rz[post_get_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await getPostRaw(
            api_key = api_key
            ,postId = postId
        )
    except CatchableError as e:
        return err[post_get_resp]($e.msg)

    let as_obj = catch req_body.asObj(post_get_resp):
        return err[post_get_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Update post
# -----------------------------
discard """
https://docs.getlate.dev/core/posts#update-a-post
"""
proc updatePostRaw*(
    api_key                : string
    ,postId                : string
    ,patch                 : JsonNode
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/posts/{postId}"

    var
        async_client       = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers   = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    try:
        let
            resp           = await async_client.request(
                url         = url
                ,httpMethod = HttpPut
                ,body       = $patch
            )
            resp_body      = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/posts#update-a-post
"""
proc updatePost*(
    api_key                : string
    ,postId                : string
    ,patch                 : JsonNode
) : Future[rz.Rz[post_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await updatePostRaw(
            api_key = api_key
            ,postId = postId
            ,patch  = patch
        )
    except CatchableError as e:
        return err[post_write_resp]($e.msg)

    let as_obj = catch req_body.asObj(post_write_resp):
        return err[post_write_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Delete post
# -----------------------------
discard """
https://docs.getlate.dev/core/posts#delete-a-post
"""
proc deletePostRaw*(
    api_key                : string
    ,postId                : string
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/posts/{postId}"

    var
        async_client       = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers   = mk_auth_headers(
        api_key            = api_key
    )

    try:
        let
            resp           = await async_client.request(
                url         = url
                ,httpMethod = HttpDelete
            )
            resp_body      = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/posts#delete-a-post
"""
proc deletePost*(
    api_key                : string
    ,postId                : string
) : Future[rz.Rz[post_delete_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await deletePostRaw(
            api_key = api_key
            ,postId = postId
        )
    except CatchableError as e:
        return err[post_delete_resp]($e.msg)

    let as_obj = catch req_body.asObj(post_delete_resp):
        return err[post_delete_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Retry publish
# -----------------------------
discard """
https://docs.getlate.dev/core/posts#retry-publishing-a-failed-or-partial-post
"""
proc retryPostRaw*(
    api_key                : string
    ,postId                : string
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/posts/{postId}/retry"

    var
        async_client       = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers   = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    try:
        let
            resp           = await async_client.request(
                url         = url
                ,httpMethod = HttpPost
                ,body       = "{}"
            )
            resp_body      = await resp.body

        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/posts#retry-publishing-a-failed-or-partial-post
"""
proc retryPost*(
    api_key                : string
    ,postId                : string
) : Future[rz.Rz[post_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await retryPostRaw(
            api_key = api_key
            ,postId = postId
        )
    except CatchableError as e:
        return err[post_write_resp]($e.msg)

    let as_obj = catch req_body.asObj(post_write_resp):
        return err[post_write_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj



