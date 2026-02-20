## queue.nim - Late API (Queue)
##
## Docs:
##   https://docs.getlate.dev/utilities/queue

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
    queue_slot* = object
        dayOfWeek        * : int              ## 0-6 (Sunday-Saturday)
        time             * : string           ## "HH:MM" format

    queue* = object
        id               * : string
        profileId        * : Option[string]
        name             * : Option[string]
        timezone         * : Option[string]
        slots            * : Option[seq[queue_slot]]
        active           * : Option[bool]
        isDefault        * : Option[bool]
        createdAt        * : Option[string]
        updatedAt        * : Option[string]

    queue_get_resp* = object
        exists           * : Option[bool]          ## single queue response
        schedule         * : Option[queue]         ## single queue (not "queue")
        queues           * : Option[seq[queue]]    ## when all=true
        nextSlots        * : Option[seq[string]]   ## bonus: upcoming slot times

    queue_write_resp* = object
        message          * : Option[string]
        queue            * : Option[queue]

    queue_delete_resp* = object
        message          * : string

    queue_preview_slot* = object
        datetime         * : Option[string]
        dayOfWeek        * : Option[int]
        time             * : Option[string]
        queueId          * : Option[string]
        queueName        * : Option[string]

    queue_preview_resp* = object
        slots            * : Option[seq[queue_preview_slot]]
        timezone         * : Option[string]

    next_slot_resp* = object
        nextSlot         * : Option[string]       ## ISO datetime
        queueId          * : Option[string]
        queueName        * : Option[string]
        timezone         * : Option[string]


# -----------------------------
# jsony rename hooks (_id -> id)
# -----------------------------
proc renameHook*(v: var queue, fieldName: var string) =
    if fieldName == "_id": fieldName = "id"

proc renameHook*(v: var queue_preview_slot, fieldName: var string) =
    if fieldName == "_id": fieldName = "id"

proc renameHook*(v: var queue_get_resp, fieldName: var string) =
    if fieldName == "schedule": fieldName = "schedule"  # keep as-is, or map to queue if you prefer

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


proc add_query_param_int(url: var string, key: string, value: int, isFirst: var bool) =
    add_query_param(url, key, $value, isFirst)


proc add_query_param_bool(url: var string, key: string, value: bool, isFirst: var bool, includeWhenFalse = false) =
    if (not value) and (not includeWhenFalse):
        return
    add_query_param(url, key, (if value: "true" else: "false"), isFirst)


# -----------------------------
# Get queue slots
# -----------------------------
discard """
https://docs.getlate.dev/utilities/queue
GET /v1/queue/slots
Retrieve queue schedules for a profile.
- Without all=true: Returns the default queue (or specific queue if queueId provided)
- With all=true: Returns all queues for the profile
"""
proc getQueueSlotsRaw*(
    api_key              : string
    ,profileId           : string
    ,queueId             = none string
    ,all                 = false
) : Future[string] {.async.} =

    var
        url          = fmt"{base_endpoint()}/queue/slots"
        isFirst      = true
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    add_query_param(url, "profileId", profileId, isFirst)

    if queueId.isSome:
        add_query_param(url, "queueId", queueId.get, isFirst)

    add_query_param_bool(url, "all", all, isFirst, includeWhenFalse = false)

    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/utilities/queue
GET /v1/queue/slots
"""
proc getQueueSlots*(
    api_key              : string
    ,profileId           : string
    ,queueId             = none string
    ,all                 = false
) : Future[rz.Rz[queue_get_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await getQueueSlotsRaw(
            api_key    = api_key
            ,profileId = profileId
            ,queueId   = queueId
            ,all       = all
        )
    except CatchableError as e:
        return rz.err[queue_get_resp] $e.msg

    let as_obj = catch req_body.asObj(queue_get_resp):
        return rz.err[queue_get_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Create queue
# -----------------------------
discard """
https://docs.getlate.dev/utilities/queue
POST /v1/queue/slots
Create an additional queue for a profile.
The first queue created becomes the default.
Subsequent queues are non-default unless explicitly set.
"""
proc createQueueRaw*(
    api_key              : string
    ,profileId           : string
    ,name                : string
    ,timezone            : string
    ,slots               : seq[queue_slot]
    ,active              = none bool
) : Future[string] {.async.} =

    let url = fmt"{base_endpoint()}/queue/slots"

    var
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    var body = %*{
        "profileId"       : profileId
        ,"name"           : name
        ,"timezone"       : timezone
        ,"slots"          : slots
    }

    if active.isSome:
        body["active"] = % active.get

    try:
        let
            resp      = await async_client.request(
                url         = url
                ,httpMethod = HttpPost
                ,body       = $body
            )
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/utilities/queue
POST /v1/queue/slots
"""
proc createQueue*(
    api_key              : string
    ,profileId           : string
    ,name                : string
    ,timezone            : string
    ,slots               : seq[queue_slot]
    ,active              = none bool
) : Future[rz.Rz[queue_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await createQueueRaw(
            api_key    = api_key
            ,profileId = profileId
            ,name      = name
            ,timezone  = timezone
            ,slots     = slots
            ,active    = active
        )
    except CatchableError as e:
        return rz.err[queue_write_resp] $e.msg

    let as_obj = catch req_body.asObj(queue_write_resp):
        return rz.err[queue_write_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Delete queue
# -----------------------------
discard """
https://docs.getlate.dev/utilities/queue
DELETE /v1/queue/slots
Delete a queue from a profile.
Requires queueId to specify which queue to delete.
If deleting the default queue, another queue will be promoted to default.
"""
proc deleteQueueRaw*(
    api_key              : string
    ,profileId           : string
    ,queueId             : string
) : Future[string] {.async.} =

    var
        url          = fmt"{base_endpoint()}/queue/slots"
        isFirst      = true
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    add_query_param(url, "profileId", profileId, isFirst)
    add_query_param(url, "queueId", queueId, isFirst)

    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpDelete)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/utilities/queue
DELETE /v1/queue/slots
"""
proc deleteQueue*(
    api_key              : string
    ,profileId           : string
    ,queueId             : string
) : Future[rz.Rz[queue_delete_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await deleteQueueRaw(
            api_key    = api_key
            ,profileId = profileId
            ,queueId   = queueId
        )
    except CatchableError as e:
        return rz.err[queue_delete_resp] $e.msg

    let as_obj = catch req_body.asObj(queue_delete_resp):
        return rz.err[queue_delete_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Update/Upsert queue
# -----------------------------
discard """
https://docs.getlate.dev/utilities/queue
PUT /v1/queue/slots
Create a new queue or update an existing one.
- Without queueId: Creates or updates the default queue
- With queueId: Updates the specific queue
- With setAsDefault=true: Makes this queue the default for the profile
"""
proc updateQueueRaw*(
    api_key              : string
    ,profileId           : string
    ,timezone            : string
    ,slots               : seq[queue_slot]
    ,queueId             = none string
    ,name                = none string
    ,active              = none bool
    ,setAsDefault        = none bool
    ,reshuffleExisting   = none bool
) : Future[string] {.async.} =

    let url = fmt"{base_endpoint()}/queue/slots"

    var
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    var body = %*{
        "profileId"       : profileId
        ,"timezone"       : timezone
        ,"slots"          : slots
    }

    if queueId.isSome:
        body["queueId"] = % queueId.get

    if name.isSome:
        body["name"] = % name.get

    if active.isSome:
        body["active"] = % active.get

    if setAsDefault.isSome:
        body["setAsDefault"] = % setAsDefault.get

    if reshuffleExisting.isSome:
        body["reshuffleExisting"] = % reshuffleExisting.get

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
https://docs.getlate.dev/utilities/queue
PUT /v1/queue/slots
"""
proc updateQueue*(
    api_key              : string
    ,profileId           : string
    ,timezone            : string
    ,slots               : seq[queue_slot]
    ,queueId             = none string
    ,name                = none string
    ,active              = none bool
    ,setAsDefault        = none bool
    ,reshuffleExisting   = none bool
) : Future[rz.Rz[queue_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await updateQueueRaw(
            api_key           = api_key
            ,profileId        = profileId
            ,timezone         = timezone
            ,slots            = slots
            ,queueId          = queueId
            ,name             = name
            ,active           = active
            ,setAsDefault     = setAsDefault
            ,reshuffleExisting = reshuffleExisting
        )
    except CatchableError as e:
        return rz.err[queue_write_resp] $e.msg

    let as_obj = catch req_body.asObj(queue_write_resp):
        return rz.err[queue_write_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Preview queue slots
# -----------------------------
discard """
https://docs.getlate.dev/utilities/queue
GET /v1/queue/preview
Preview upcoming posting slots for a profile.
"""
proc previewQueueRaw*(
    api_key              : string
    ,profileId           : string
    ,count               = none int
) : Future[string] {.async.} =

    var
        url          = fmt"{base_endpoint()}/queue/preview"
        isFirst      = true
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    add_query_param(url, "profileId", profileId, isFirst)

    if count.isSome:
        add_query_param_int(url, "count", count.get, isFirst)

    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/utilities/queue
GET /v1/queue/preview
"""
proc previewQueue*(
    api_key              : string
    ,profileId           : string
    ,count               = none int
) : Future[rz.Rz[queue_preview_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await previewQueueRaw(
            api_key    = api_key
            ,profileId = profileId
            ,count     = count
        )
    except CatchableError as e:
        return rz.err[queue_preview_resp] $e.msg

    let as_obj = catch req_body.asObj(queue_preview_resp):
        return rz.err[queue_preview_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Get next available slot
# -----------------------------
discard """
https://docs.getlate.dev/utilities/queue
GET /v1/queue/next-slot
Returns the next available posting slot, taking into account already
scheduled posts to avoid conflicts. Useful for scheduling posts via
queue without manual time selection.

If no queueId is specified, uses the profile's default queue.
"""
proc nextSlotRaw*(
    api_key              : string
    ,profileId           : string
    ,queueId             = none string
) : Future[string] {.async.} =

    var
        url          = fmt"{base_endpoint()}/queue/next-slot"
        isFirst      = true
        async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)

    add_query_param(url, "profileId", profileId, isFirst)

    if queueId.isSome:
        add_query_param(url, "queueId", queueId.get, isFirst)

    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/utilities/queue
GET /v1/queue/next-slot
"""
proc nextSlot*(
    api_key              : string
    ,profileId           : string
    ,queueId             = none string
) : Future[rz.Rz[next_slot_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await nextSlotRaw(
            api_key    = api_key
            ,profileId = profileId
            ,queueId   = queueId
        )
    except CatchableError as e:
        return rz.err[next_slot_resp] $e.msg

    let as_obj = catch req_body.asObj(next_slot_resp):
        return rz.err[next_slot_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Convenience: Create queue slot helper
# -----------------------------
proc qSlot*(dayOfWeek: int, time: string): queue_slot =
    ## Helper to create a queue_slot
    ## dayOfWeek: 0-6 (Sunday-Saturday)
    ## time: "HH:MM" format (e.g., "09:00", "18:30")
    queue_slot(
        dayOfWeek : dayOfWeek
        ,time     : time
    )


# Day-of-week constants for readability
const
    Sunday*    = 0
    Monday*    = 1
    Tuesday*   = 2
    Wednesday* = 3
    Thursday*  = 4
    Friday*    = 5
    Saturday*  = 6