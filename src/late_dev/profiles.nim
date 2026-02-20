## profiles.nim - Late API (Profiles)
##
## Docs:
##   https://docs.getlate.dev/core/profiles

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

    profile_summary * = object
        id          * : string
        name        * : string
        color       * : Option[string]
        isDefault   * : bool
        isOverLimit * : Option[bool]

    profile               * = object
        id                * : string
        userId            * : string
        name              * : string
        description       * : string
        color             * : string
        isDefault         * : bool
        createdAt         * : string
        updatedAt         * : string

    profiles_list_resp    * = object
        profiles          * : seq[profile_summary]

    profile_get_resp      * = object
        profile           * : profile

    profile_write_resp    * = object
        message           * : string
        profile           * : profile

    profile_delete_resp   * = object
        message           * : string



proc renameHook*(
    v                 : var profile_summary
    ,fieldName        : var string
) =
    if fieldName == "_id":
        fieldName = "id"


proc renameHook*(
    v                 : var profile
    ,fieldName        : var string
) =
    if fieldName == "_id":
        fieldName = "id"


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


# -----------------------------
# List profiles
# -----------------------------
proc listProfilesRaw*(
    api_key                  : string
    ,includeOverLimit        = false
) : Future[string] {.async.} = # json_string

    var
        url              = fmt"{base_endpoint()}/profiles"
        async_client     = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    if includeOverLimit:
        url.add "?includeOverLimit=true"

    async_client.headers = mk_auth_headers(
        api_key          = api_key
    )

    try:
        let
            resp            = await async_client.request(
                url         = url
                ,httpMethod = HttpGet
            )
            resp_body     = await resp.body


        return resp_body
    finally:
        async_client.close()


proc listProfiles*(
    api_key              : string
    ,includeOverLimit    = false
) : Future[rz.Rz[profiles_list_resp]] {.async.} =

    var req_body : string
    try:
        req_body              = await listProfilesRaw(
            api_key           = api_key
            ,includeOverLimit = includeOverLimit
        )
    except CatchableError as e:
        return err[profiles_list_resp]($e.msg)

    let as_obj = catch req_body.asObj(profiles_list_resp):
        return err[profiles_list_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Create profile
# -----------------------------
proc createProfileRaw*(
    api_key              : string
    ,name                : string
    ,description         = none string
    ,color               = none string
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/profiles"

    var
        async_client     = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    var body = %*{
        "name"            : name
    }

    if description.isSome:
        body["description"] = % description.get

    if color.isSome:
        body["color"]       = % color.get

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


proc createProfile*(
    api_key              : string
    ,name                : string
    ,description         = none string
    ,color               = none string
) : Future[rz.Rz[profile_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await createProfileRaw(
            api_key      = api_key
            ,name        = name
            ,description = description
            ,color       = color
        )
    except CatchableError as e:
        return err[profile_write_resp]($e.msg)

    let as_obj = catch req_body.asObj(profile_write_resp):
        return err[profile_write_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Get profile by id
# -----------------------------
proc getProfileRaw*(
    api_key              : string
    ,profileId           : string
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/profiles/{profileId}"
    icb url

    var
        async_client     = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
    )

    try:
        let
            resp          = await async_client.request(
                url         = url
                ,httpMethod = HttpGet
            )
            resp_body     = await resp.body

        return resp_body
    finally:
        async_client.close()


proc getProfile*(
    api_key              : string
    ,profileId           : string
) : Future[rz.Rz[profile_get_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await getProfileRaw(
            api_key    = api_key
            ,profileId = profileId
        )
    except CatchableError as e:
        return err[profile_get_resp]($e.msg)

    let as_obj = catch req_body.asObj(profile_get_resp):
        return err[profile_get_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


# -----------------------------
# Update profile
# -----------------------------
proc updateProfileRaw*(
    api_key              : string
    ,profileId           : string
    ,name                = none string
    ,description         = none string
    ,color               = none string
    ,isDefault           = none bool
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/profiles/{profileId}"

    var
        async_client     = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
        ,content_type_json = true
    )

    var body = newJObject()

    if name.isSome:
        body["name"]        = % name.get

    if description.isSome:
        body["description"] = % description.get

    if color.isSome:
        body["color"]       = % color.get

    if isDefault.isSome:
        body["isDefault"]   = % isDefault.get

    try:
        let
            resp          = await async_client.request(
                url         = url
                ,httpMethod = HttpPut
                ,body       = $body
            )
            resp_body     = await resp.body


        return resp_body
    finally:
        async_client.close()


proc updateProfile*(
    api_key              : string
    ,profileId           : string
    ,name                = none string
    ,description         = none string
    ,color               = none string
    ,isDefault           = none bool
) : Future[rz.Rz[profile_write_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await updateProfileRaw(
            api_key      = api_key
            ,profileId   = profileId
            ,name        = name
            ,description = description
            ,color       = color
            ,isDefault   = isDefault
        )
    except CatchableError as e:
        return err[profile_write_resp]($e.msg)

    let as_obj = catch req_body.asObj(profile_write_resp):
        return err[profile_write_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}" 

    return rz.ok  as_obj


# -----------------------------
# Delete profile
# -----------------------------
proc deleteProfileRaw*(
    api_key              : string
    ,profileId           : string
) : Future[string] {.async.} = # json_string

    let url = fmt"{base_endpoint()}/profiles/{profileId}"

    var
        async_client     = newAsyncHttpClient(userAgent = "curl/8.4.0", maxRedirects = 0)

    async_client.headers = mk_auth_headers(
        api_key            = api_key
    )

    try:
        let
            resp          = await async_client.request(
                url         = url
                ,httpMethod = HttpDelete
            )
            resp_body     = await resp.body


        return resp_body
    finally:
        async_client.close()


proc deleteProfile*(
    api_key              : string
    ,profileId           : string
) : Future[rz.Rz[profile_delete_resp]] {.async.} =

    var req_body : string
    try:
        req_body = await deleteProfileRaw(
            api_key    = api_key
            ,profileId = profileId
        )
    except CatchableError as e:
        return err[profile_delete_resp]($e.msg)

    let as_obj = catch req_body.asObj(profile_delete_resp):
        return err[profile_delete_resp] &"Error parsing response to object. \nResponse -> {req_body}\nParsing Error -> {it.err}"

    return rz.ok as_obj


