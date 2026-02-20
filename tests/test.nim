# Std Lib
import std/[
    asyncdispatch
    ,json
    ,options
    ,os
    ,strformat
    ,strutils
    ,unittest
]

# External Pkgs
import ic
    ,rz

# Local Files
import ../src/late_dev/[
    accounts
    ,downloads
    ,media
    ,posts
    ,profiles
    ,webhooks
    ,queue
]


const
    c_api_key   {.strdefine.}  = ""
    c_profileId {.strdefine.}  = ""
    use_keys    {.booldefine.} = false

when use_keys:
    import mynimlib/keys

var
    api_key   = if use_keys : keys.ld_api_key    else : c_api_key
    profileId = if use_keys : keys.ld_profileId  else : c_profileId

icb c_api_key, c_profileId, use_keys

if api_key.len == 0:
    icr "Please set api_key before running tests (use -d:api_key=... or -d:use_keys)"
    quit(1)

if profileId.len == 0:
    icr "Please set profileId before running tests (use -d:profileId=... or -d:use_keys)"
    quit(1)


proc ensure_success_json(body: string, ctx: string) =
    ## Fails the test if body looks like an error response.
    var j: JsonNode
    try:
        j = parseJson(body)
    except CatchableError:
        doAssert false, "Invalid JSON response: " & ctx & "\nBody -> " & body

    # If API uses { "success": true }
    if j.kind == JObject and j.hasKey("success"):
        if j["success"].kind == JBool and j["success"].getBool:
            return
        doAssert false, "Request not successful: " & ctx & "\nBody -> " & body

    # If API uses { "error": "..." }
    if j.kind == JObject and j.hasKey("error"):
        let e = j["error"]
        if e.kind == JString:
            let es = e.getStr
            doAssert false, "API Error: " & ctx & "\nError -> " & es & "\nBody -> " & body
        else:
            doAssert false, "API Error: " & ctx & "\nBody -> " & $e

    # Otherwise: accept (some endpoints may return formats list, etc.)
    doAssert body.len > 0, "Empty response: " & ctx


discard """
nim r -d:ssl -d:ic -d:api_key=.. -d:profileId=... ./tests/test "queue.nim::"
nim r -d:ssl -d:ic -d:use_keys ./tests/test "queue.nim::"
"""
suite "queue.nim":
    test "get queue slots (default)":
        let body = waitFor getQueueSlotsRaw(
            api_key    = api_key
            ,profileId = profileId
        )
        ic body
        ensure_success_json(body, "get queue slots (default)")

    test "get queue slots (all)":
        let body = waitFor getQueueSlotsRaw(
            api_key    = api_key
            ,profileId = profileId
            ,all       = true
        )
        ic body
        ensure_success_json(body, "get queue slots (all)")

    test "preview queue":
        let body = waitFor previewQueueRaw(
            api_key    = api_key
            ,profileId = profileId
            ,count     = some 5
        )
        ic body
        ensure_success_json(body, "preview queue")

    test "next slot":
        let body = waitFor nextSlotRaw(
            api_key    = api_key
            ,profileId = profileId
        )
        ic body
        ensure_success_json(body, "next slot")

    test "create, update, delete queue":
        # Create a test queue
        let createBody = waitFor createQueueRaw(
            api_key    = api_key
            ,profileId = profileId
            ,name      = "Test Queue (SDK)"
            ,timezone  = "America/New_York"
            ,slots     = @[
                qSlot(Monday, "10:00")
                ,qSlot(Wednesday, "10:00")
                ,qSlot(Friday, "10:00")
            ]
            ,active    = some false
        )
        ic createBody
        ensure_success_json(createBody, "create queue")

        # Extract queue ID from response (API returns "schedule" not "queue")
        let createJson = parseJson(createBody)
        let queueId = createJson{"schedule", "_id"}.getStr(
            createJson{"schedule", "id"}.getStr(
                createJson{"queue", "_id"}.getStr(
                    createJson{"queue", "id"}.getStr("")
                )
            )
        )
        check queueId.len > 0

        # Update the queue
        let updateBody = waitFor updateQueueRaw(
            api_key    = api_key
            ,profileId = profileId
            ,queueId   = some queueId
            ,timezone  = "America/Chicago"
            ,slots     = @[
                qSlot(Tuesday, "14:00")
                ,qSlot(Thursday, "14:00")
            ]
            ,name      = some "Updated Test Queue (SDK)"
            ,active    = some false
        )
        ic updateBody
        ensure_success_json(updateBody, "update queue")

        # Delete the queue
        let deleteBody = waitFor deleteQueueRaw(
            api_key    = api_key
            ,profileId = profileId
            ,queueId   = queueId
        )
        ic deleteBody
        ensure_success_json(deleteBody, "delete queue")

    test "qSlot helper":
        let slot = qSlot(Monday, "09:00")
        check slot.dayOfWeek == 1
        check slot.time == "09:00"

        let slot2 = qSlot(Sunday, "18:30")
        check slot2.dayOfWeek == 0
        check slot2.time == "18:30"

    test "day constants":
        check Sunday == 0
        check Monday == 1
        check Tuesday == 2
        check Wednesday == 3
        check Thursday == 4
        check Friday == 5
        check Saturday == 6



discard """
nim r -d:ssl -d:ic -d:api_key=.. -d:profileId=... ./tests/test "media.nim::"
nim r -d:ssl -d:ic -d:use_keys ./tests/test "media.nim::"
"""
suite "media.nim":

    echo "suite setup: run once before the tests"

    test "upload jpg":
        let test_file_path = "tests/test.jpg"
        if not test_file_path.fileExists:
            icr fmt"Test file not found: {test_file_path}"
            quit(1)

        let resp = catch waitFor api_key.mediaUploadFile(test_file_path):
            icr "mediaUploadFile failed: " & it.err
            quit(1)

        ic resp
        check resp.len > 0


    test "upload mp4":
        let test_file_path = "tests/Big_Buck_Bunny_1080_10s_30MB.mp4"
        if not test_file_path.fileExists:
            icr fmt"Test file not found: {test_file_path}"
            quit(1)

        let resp = catch waitFor api_key.mediaUploadFile(test_file_path):
            icr "mediaUploadFile failed: " & it.err
            quit(1)

        ic resp
        check resp.len > 0


discard """
nim r -d:ssl -d:ic -d:api_key=.. -d:profileId=... ./tests/test "downloads.nim::"
nim r -d:ssl -d:ic -d:use_keys ./tests/test "downloads.nim::"
"""
suite "downloads.nim":

    test "twitter/x downloads":
        let urls = @[
            "https://x.com/LostMemeArchive/status/2012978301124702596?s=20"
            ,"https://x.com/shiri_shh/status/2012390717457367522?s=20"
        ]

        for u in urls:
            icb u
            let body = waitFor twitterDownloadRaw(
                api_key = api_key
                ,url    = u
            )
            ic body
            ensure_success_json(body, "twitter url=" & u)


    discard """
    # {"error":"{ \"status\": 400, \"message\": \"No longer working\" }"}
    test "tiktok downloads":
        let urls = @[
            "https://www.tiktok.com/@auxchordapp/video/7595727261966388494"
            ,"https://www.tiktok.com/@donttellcomedy/video/7589372867456797966?is_from_webapp=1&sender_device=pc"
        ]

        for u in urls:
            icb u
            let body = waitFor tiktokDownloadRaw(
                api_key = api_key
                ,url    = u
            )
            ic body
            ensure_success_json(body, "tiktok url=" & u)
    """


    test "instagram downloads":
        let urls = @[
            "https://www.instagram.com/p/DToICYQke_H/?hl=en"
            ,"https://www.instagram.com/p/DTgFtufkV6n/?hl=en&img_index=1"
        ]

        for u in urls:
            icb u
            let body = waitFor instagramDownloadRaw(
                api_key = api_key
                ,url    = u
            )
            ic body
            ensure_success_json(body, "instagram url=" & u)


discard """
nim r -d:ssl -d:ic -d:api_key=.. -d:profileId=... ./tests/test "profiles.nim::"
nim r -d:ssl -d:ic -d:use_keys ./tests/test "profiles.nim::"
"""
suite "profiles.nim":

    echo "suite setup: run once before the tests"

    setup:
        echo "run before each test"

    teardown:
        echo "run after each test"


    test "listProfilesRaw":
        let body = waitFor listProfilesRaw(
            api_key           = api_key
            ,includeOverLimit = true
        )
        ic body
        check body.len > 0


    test "listProfiles":
        let resp = waitFor listProfiles(
            api_key           = api_key
            ,includeOverLimit = true
        )
        resp.isErr:
            icr resp.err
            check false

        ic resp.val
        check resp.val.profiles.len >= 0


    test "getProfileRaw":
        let body = waitFor getProfileRaw(
            api_key    = api_key
            ,profileId = profileId
        )
        ic body
        check body.len > 0


    test "getProfile":
        let resp = waitFor getProfile(
            api_key    = api_key
            ,profileId = profileId
        )
        resp.isErr:
            icr resp.err
            check false

        ic resp.val
        check resp.val.profile.id.len > 0
        check resp.val.profile.name.len > 0


    test "create -> update -> delete (best effort)":

        let created = waitFor createProfile(
            api_key      = api_key
            ,name        = "nim_test_profile"
            ,description = some "created by tests/test.nim"
            ,color       = some "#2196F3"
        )
        created.isErr:
            icr created.err
            check false

        let createdId = created.val.profile.id
        icb created.val

        check createdId.len > 0

        let updated = waitFor updateProfile(
            api_key      = api_key
            ,profileId   = createdId
            ,name        = some "nim_test_profile_updated"
            ,description = some "updated by tests/test.nim"
            ,color       = some "#4CAF50"
            ,isDefault   = some false
        )
        updated.isErr:
            icr updated.err
            check false

        check updated.val.profile.id == createdId
        check updated.val.profile.name.len > 0

        let deleted = waitFor deleteProfile(
            api_key    = api_key
            ,profileId = createdId
        )
        deleted.isErr:
            icr deleted.err
            check false

        ic deleted.val
        check deleted.val.message.len > 0


    echo "suite teardown: run once after the tests"
