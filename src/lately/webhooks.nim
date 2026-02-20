# webhooks.nim - Late API (Webhooks)
#
# Docs:
#   https://docs.getlate.dev/core/webhooks

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


when not declared(base_endpoint):
    proc base_url()      : string = "https://getlate.dev/api"
    proc api_version()   : string = "v1"
    proc base_endpoint() : string = fmt"{base_url()}/{api_version()}"


type
    webhook_event* = enum
        post_scheduled
        post_published
        post_failed
        post_partial
        account_connected
        account_disconnected

    webhook_setting     * = object
        id              * : string
        name            * : Option[string]
        url             * : Option[string]
        secret          * : Option[string]
        events          * : Option[seq[string]]
        isActive        * : Option[bool]
        customHeaders   * : Option[JsonNode]   # object of { "Header-Name": "value", ... }

    webhooks_settings_resp* = object
        webhooks         * : seq[webhook_setting]

    webhook_write_resp* = object
        message          * : Option[string]
        webhook          * : Option[webhook_setting]
        webhooks         * : Option[seq[webhook_setting]] # some APIs return list; keep flexible

    webhook_delete_resp* = object
        message          * : Option[string]

    webhook_test_resp* = object
        message          * : Option[string]

    webhook_log_item* = object
        id              * : string
        webhookId       * : Option[string]
        event           * : Option[string]
        status          * : Option[string]
        createdAt       * : Option[string]
        responseStatus  * : Option[int]
        error           * : Option[string]

    webhook_logs_resp* = object
        logs            * : Option[seq[webhook_log_item]]


proc renameHook*(v: var webhook_setting, fieldName: var string) =
    if fieldName == "_id":
        fieldName = "id"


proc renameHook*(v: var webhook_log_item, fieldName: var string) =
    if fieldName == "_id":
        fieldName = "id"


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


proc to_event_string*(e: webhook_event): string =
    case e
    of post_scheduled:        "post.scheduled"
    of post_published:        "post.published"
    of post_failed:           "post.failed"
    of post_partial:          "post.partial"
    of account_connected:     "account.connected"
    of account_disconnected:  "account.disconnected"


proc to_event_strings*(events: seq[webhook_event]): seq[string] =
    result = @[]
    for e in events:
        result.add e.to_event_string()


discard """
https://docs.getlate.dev/core/webhooks#retrieve-all-configured-webhooks
GET /v1/webhooks/settings
"""
proc webhooksListRaw*(
    api_key              : string
) : Future[string] {.async.} =

    let url = fmt"{base_endpoint()}/webhooks/settings"

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
https://docs.getlate.dev/core/webhooks#retrieve-all-configured-webhooks
GET /v1/webhooks/settings
"""
proc webhooksList*(
    api_key              : string
) : Future[rz.Rz[webhooks_settings_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await webhooksListRaw(api_key = api_key)
    except CatchableError as e:
        return rz.err[webhooks_settings_resp] $e.msg

    let as_obj = catch req_body.asObj(webhooks_settings_resp):
        return rz.err[webhooks_settings_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


discard """
https://docs.getlate.dev/core/webhooks#create-a-new-webhook-configuration
POST /v1/webhooks/settings
"""
proc webhooksCreateRaw*(
    api_key              : string
    ,name                = none string
    ,url                 = none string
    ,secret              = none string
    ,events              = none seq[string]
    ,isActive            = none bool
    ,customHeaders       = none JsonNode
) : Future[string] {.async.} =

    let url_ep = fmt"{base_endpoint()}/webhooks/settings"

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key, content_type_json = true)

    var body = newJObject()

    if name.isSome:          body["name"]          = % name.get
    if url.isSome:           body["url"]           = % url.get
    if secret.isSome:        body["secret"]        = % secret.get
    if events.isSome:        body["events"]        = % events.get
    if isActive.isSome:      body["isActive"]      = % isActive.get
    if customHeaders.isSome: body["customHeaders"] = customHeaders.get

    try:
        let
            resp      = await async_client.request(
                url         = url_ep
                ,httpMethod = HttpPost
                ,body       = $body
            )
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/webhooks#create-a-new-webhook-configuration
POST /v1/webhooks/settings
"""
proc webhooksCreate*(
    api_key              : string
    ,name                = none string
    ,url                 = none string
    ,secret              = none string
    ,events              = none seq[string]
    ,isActive            = none bool
    ,customHeaders       = none JsonNode
) : Future[rz.Rz[webhook_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await webhooksCreateRaw(
            api_key        = api_key
            ,name          = name
            ,url           = url
            ,secret        = secret
            ,events        = events
            ,isActive      = isActive
            ,customHeaders = customHeaders
        )
    except CatchableError as e:
        return rz.err[webhook_write_resp] $e.msg

    let as_obj = catch req_body.asObj(webhook_write_resp):
        return rz.err[webhook_write_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


discard """
https://docs.getlate.dev/core/webhooks#update-an-existing-webhook-configuration
PUT /v1/webhooks/settings
"""
proc webhooksUpdateRaw*(
    api_key              : string
    ,id                  : string
    ,name                = none string
    ,url                 = none string
    ,secret              = none string
    ,events              = none seq[string]
    ,isActive            = none bool
    ,customHeaders       = none JsonNode
) : Future[string] {.async.} =

    let url_ep = fmt"{base_endpoint()}/webhooks/settings"

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key, content_type_json = true)

    var body = newJObject()
    body["_id"] = % id

    if name.isSome:          body["name"]          = % name.get
    if url.isSome:           body["url"]           = % url.get
    if secret.isSome:        body["secret"]        = % secret.get
    if events.isSome:        body["events"]        = % events.get
    if isActive.isSome:      body["isActive"]      = % isActive.get
    if customHeaders.isSome: body["customHeaders"] = customHeaders.get

    try:
        let
            resp      = await async_client.request(
                url         = url_ep
                ,httpMethod = HttpPut
                ,body       = $body
            )
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/webhooks#update-an-existing-webhook-configuration
PUT /v1/webhooks/settings
"""
proc webhooksUpdate*(
    api_key              : string
    ,id                  : string
    ,name                = none string
    ,url                 = none string
    ,secret              = none string
    ,events              = none seq[string]
    ,isActive            = none bool
    ,customHeaders       = none JsonNode
) : Future[rz.Rz[webhook_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await webhooksUpdateRaw(
            api_key        = api_key
            ,id            = id
            ,name          = name
            ,url           = url
            ,secret        = secret
            ,events        = events
            ,isActive      = isActive
            ,customHeaders = customHeaders
        )
    except CatchableError as e:
        return rz.err[webhook_write_resp] $e.msg

    let as_obj = catch req_body.asObj(webhook_write_resp):
        return rz.err[webhook_write_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


discard """
https://docs.getlate.dev/core/webhooks#permanently-delete-a-webhook-configuration
DELETE /v1/webhooks/settings?id=...
"""
proc webhooksDeleteRaw*(
    api_key              : string
    ,id                  : string
) : Future[string] {.async.} =

    var
        url_ep       = fmt"{base_endpoint()}/webhooks/settings"
        isFirst      = true

    add_query_param(url_ep, "id", id, isFirst)

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url_ep, httpMethod = HttpDelete)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/webhooks#permanently-delete-a-webhook-configuration
DELETE /v1/webhooks/settings?id=...
"""
proc webhooksDelete*(
    api_key              : string
    ,id                  : string
) : Future[rz.Rz[webhook_delete_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await webhooksDeleteRaw(api_key = api_key, id = id)
    except CatchableError as e:
        return rz.err[webhook_delete_resp] $e.msg

    let as_obj = catch req_body.asObj(webhook_delete_resp):
        return rz.err[webhook_delete_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


discard """
https://docs.getlate.dev/core/webhooks#send-a-test-webhook
POST /v1/webhooks/test
"""
proc webhooksTestRaw*(
    api_key              : string
    ,webhookId           : string
) : Future[string] {.async.} =

    let url_ep = fmt"{base_endpoint()}/webhooks/test"

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key, content_type_json = true)

    var body = %*{
        "webhookId"       : webhookId
    }

    try:
        let
            resp      = await async_client.request(
                url         = url_ep
                ,httpMethod = HttpPost
                ,body       = $body
            )
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/webhooks#send-a-test-webhook
POST /v1/webhooks/test
"""
proc webhooksTest*(
    api_key              : string
    ,webhookId           : string
) : Future[rz.Rz[webhook_test_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await webhooksTestRaw(api_key = api_key, webhookId = webhookId)
    except CatchableError as e:
        return rz.err[webhook_test_resp] $e.msg

    let as_obj = catch req_body.asObj(webhook_test_resp):
        return rz.err[webhook_test_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


discard """
https://docs.getlate.dev/core/webhooks#retrieve-webhook-delivery-history
GET /v1/webhooks/logs
"""
proc webhooksLogsRaw*(
    api_key              : string
    ,limit               = none int
    ,status              = none string
    ,event               = none string
    ,webhookId           = none string
) : Future[string] {.async.} =

    var
        url_ep       = fmt"{base_endpoint()}/webhooks/logs"
        isFirst      = true

    if limit.isSome:     add_query_param_int(url_ep, "limit", limit.get, isFirst)
    if status.isSome:    add_query_param(url_ep, "status", status.get, isFirst)
    if event.isSome:     add_query_param(url_ep, "event", event.get, isFirst)
    if webhookId.isSome: add_query_param(url_ep, "webhookId", webhookId.get, isFirst)

    var async_client = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 5)
    async_client.headers = mk_auth_headers(api_key = api_key)

    try:
        let
            resp      = await async_client.request(url = url_ep, httpMethod = HttpGet)
            resp_body = await resp.body
        return resp_body
    finally:
        async_client.close()


discard """
https://docs.getlate.dev/core/webhooks#retrieve-webhook-delivery-history
GET /v1/webhooks/logs
"""
proc webhooksLogs*(
    api_key              : string
    ,limit               = none int
    ,status              = none string
    ,event               = none string
    ,webhookId           = none string
) : Future[rz.Rz[webhook_logs_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await webhooksLogsRaw(
            api_key    = api_key
            ,limit     = limit
            ,status    = status
            ,event     = event
            ,webhookId = webhookId
        )
    except CatchableError as e:
        return rz.err[webhook_logs_resp] $e.msg

    let as_obj = catch req_body.asObj(webhook_logs_resp):
        return rz.err[webhook_logs_resp] &"Error parsing response to object.\nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj
