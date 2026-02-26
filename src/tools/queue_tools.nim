## queue_tools.nim - Queue management tools for GLD Agent
##
## Tools for viewing and managing the post queue.

import
    std/[
        json
        ,asyncdispatch
        ,strformat
        ,options
    ]

import
    llmm
    ,llmm/tools

import
    ../lately/queue as late_queue
    ,../gld/src/store_config
    ,agent_config

# -----------------------------------------------------------------------------
# View Queue Tool
# -----------------------------------------------------------------------------

proc ViewQueueTool*(): Tool =
    ## View the queue configuration for a profile
    Tool(
        name        : "view_queue"
        ,description: "View the queue configuration for a profile. Shows queue slots (recurring posting times)."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "profileId": {
                    "type": "string"
                    ,"description": "Optional profile ID to filter by"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                let profileId = if args.hasKey("profileId") and args["profileId"].getStr.len > 0:
                    args["profileId"].getStr
                else:
                    conf.profileId.get("")

                if profileId.len == 0:
                    return toolError("No profile ID specified. Provide one or set a default profile.")

                let res = await late_queue.getQueueSlots(apiKey, profileId)

                if not res.ok:
                    return toolError(&"Failed to fetch queue: {res.err}")

                let queueData = res.val
                
                # Extract queue information
                var queueInfo: JsonNode
                var slotCount = 0
                
                if queueData.schedule.isSome:
                    let q = queueData.schedule.get
                    if q.slots.isSome:
                        slotCount = q.slots.get.len
                    
                    queueInfo = %*{
                        "id": q.id
                        ,"name": q.name.get("")
                        ,"timezone": q.timezone.get("")
                        ,"active": q.active.get(false)
                        ,"isDefault": q.isDefault.get(false)
                        ,"slotCount": slotCount
                    }
                else:
                    queueInfo = %*{}

                return toolSuccess(%*{
                    "queue": queueInfo
                    ,"nextSlots": queueData.nextSlots.get(@[])
                }, &"Queue has {slotCount} recurring slot(s)")

            except CatchableError as e:
                return toolError(&"Error fetching queue: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Get Next Queue Slot Tool
# -----------------------------------------------------------------------------

proc NextQueueSlotTool*(): Tool =
    ## Get the next available queue slot
    Tool(
        name        : "next_queue_slot"
        ,description: "Get information about the next available queue slot for posting."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "profileId": {
                    "type": "string"
                    ,"description": "Optional profile ID"
                }
            }
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let conf = loadConfig()
                let apiKey = requireApiKey(conf)

                let profileId = if args.hasKey("profileId") and args["profileId"].getStr.len > 0:
                    args["profileId"].getStr
                else:
                    conf.profileId.get("")

                if profileId.len == 0:
                    return toolError("No profile ID specified. Provide one or set a default profile.")

                let res = await late_queue.nextSlot(apiKey, profileId)

                if not res.ok:
                    return toolError(&"Failed to get next slot: {res.err}")

                let slot = res.val

                return toolSuccess(%*{
                    "nextSlot": slot.nextSlot.get("")
                    ,"queueId": slot.queueId.get("")
                }, &"Next slot: {slot.nextSlot.get(\"not available\")}")

            except CatchableError as e:
                return toolError(&"Error getting next slot: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Queue Toolkit
# -----------------------------------------------------------------------------

proc QueueToolkit*(): Toolkit =
    ## Toolkit for managing the post queue
    result = newToolkit("lately_queue", "View and manage the post queue")
    result.add ViewQueueTool()
    result.add NextQueueSlotTool()
