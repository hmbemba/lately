## ideas_tools.nim - Agent tools for GLD Ideas CRUD operations
##
## Provides natural language interface to the ideas database.
## Uses llmm's Tool factory pattern (Tools are final objects, not inheritable).

import
    std/[
        strformat
        ,strutils
        ,sequtils
        ,options
        ,json
        ,asyncdispatch
    ]

import
    llmm
    ,llmm/tools

import
    ../gld/src/ideas_db

# -----------------------------------------------------------------------------
# Helper: Convert Idea to JSON for tool responses
# -----------------------------------------------------------------------------

proc ideaToJson(idea: Idea): JsonNode =
    ## Convert an Idea to JSON representation
    result = %*{
        "id": idea.id,
        "content": idea.content,
        "status": $idea.status,
        "priority": idea.priority,
        "starred": idea.starred,
        "tags": idea.tags.split(",").filterIt(it.len > 0),
        "createdAt": idea.createdAt,
        "updatedAt": idea.updatedAt
    }
    
    if idea.link.isSome:
        result["link"] = %idea.link.get()
    if idea.linkTitle.isSome:
        result["linkTitle"] = %idea.linkTitle.get()
    if idea.notes.isSome:
        result["notes"] = %idea.notes.get()

proc ideasToJson(ideas: seq[Idea]): JsonNode =
    ## Convert a sequence of Ideas to JSON
    result = newJArray()
    for idea in ideas:
        result.add ideaToJson(idea)

# -----------------------------------------------------------------------------
# Tool: Create Idea
# -----------------------------------------------------------------------------

proc createIdeaHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let content = args{"content"}.getStr()
    if content.len == 0:
        return %*{"error": "Content is required"}
    
    let link = if args.hasKey("link") and args["link"].getStr().len > 0: 
        some(args["link"].getStr()) 
    else: 
        none(string)
    
    let notes = if args.hasKey("notes") and args["notes"].getStr().len > 0: 
        some(args["notes"].getStr()) 
    else: 
        none(string)
    
    var tags: seq[string] = @[]
    if args.hasKey("tags"):
        for tag in args["tags"]:
            tags.add tag.getStr()
    
    let priority = if args.hasKey("priority"): args["priority"].getInt() else: 0
    let starred = if args.hasKey("starred"): args["starred"].getBool() else: false
    
    let db = openIdeasDb()
    let idea = db.createIdea(
        content = content,
        link = link,
        notes = notes,
        tags = tags,
        priority = priority,
        starred = starred
    )
    
    return %*{
        "success": true,
        "message": &"Created idea #{idea.id}",
        "idea": ideaToJson(idea)
    }

proc newCreateIdeaTool*(): Tool =
    Tool(
        name: "create_idea",
        description: "Create a new idea with content, optional link, notes, tags, and priority",
        parameters: %*{
            "type": "object",
            "required": ["content"],
            "properties": {
                "content": {
                    "type": "string",
                    "description": "The main idea text/content"
                },
                "link": {
                    "type": "string",
                    "description": "Optional URL reference"
                },
                "notes": {
                    "type": "string",
                    "description": "Optional longer notes/description"
                },
                "tags": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Tags to categorize the idea"
                },
                "priority": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 3,
                    "description": "Priority level: 0=none, 1=low, 2=medium, 3=high"
                },
                "starred": {
                    "type": "boolean",
                    "description": "Whether to mark the idea as starred"
                }
            }
        },
        handler: createIdeaHandler
    )

# -----------------------------------------------------------------------------
# Tool: List Ideas
# -----------------------------------------------------------------------------

proc listIdeasHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let db = openIdeasDb()
    
    var status: Option[IdeaStatus]
    if args.hasKey("status"):
        case args["status"].getStr().toLowerAscii()
        of "active": status = some(isActive)
        of "done": status = some(isDone)
        of "archived": status = some(isArchived)
        of "all": status = none(IdeaStatus)
        else: status = some(isActive)
    else:
        status = some(isActive)
    
    let tag = if args.hasKey("tag") and args["tag"].getStr().len > 0: 
        some(args["tag"].getStr()) 
    else: 
        none(string)
    
    let starredOnly = if args.hasKey("starred"): args["starred"].getBool() else: false
    let limit = if args.hasKey("limit"): args["limit"].getInt() else: 50
    
    let ideas = db.listIdeas(
        status = status,
        tag = tag,
        starredOnly = starredOnly,
        limit = limit
    )
    
    let statusLabel = if status.isSome: $status.get() else: "all"
    
    return %*{
        "success": true,
        "count": ideas.len,
        "statusFilter": statusLabel,
        "ideas": ideasToJson(ideas)
    }

proc newListIdeasTool*(): Tool =
    Tool(
        name: "list_ideas",
        description: "List ideas with optional filtering by status, tag, or starred",
        parameters: %*{
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "enum": ["active", "done", "archived", "all"],
                    "description": "Filter by status (default: active)"
                },
                "tag": {
                    "type": "string",
                    "description": "Filter by tag"
                },
                "starred": {
                    "type": "boolean",
                    "description": "Show only starred ideas"
                },
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100,
                    "default": 50,
                    "description": "Maximum number of ideas to return"
                }
            }
        },
        handler: listIdeasHandler
    )

# -----------------------------------------------------------------------------
# Tool: Get Idea by ID
# -----------------------------------------------------------------------------

proc getIdeaHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    let db = openIdeasDb()
    let ideaOpt = db.getIdea(id)
    
    if ideaOpt.isNone:
        return %*{"error": &"Idea #{id} not found"}
    
    return %*{
        "success": true,
        "idea": ideaToJson(ideaOpt.get())
    }

proc newGetIdeaTool*(): Tool =
    Tool(
        name: "get_idea",
        description: "Get full details of a specific idea by its ID",
        parameters: %*{
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {
                    "type": "integer",
                    "description": "The idea ID number"
                }
            }
        },
        handler: getIdeaHandler
    )

# -----------------------------------------------------------------------------
# Tool: Search Ideas
# -----------------------------------------------------------------------------

proc searchIdeasHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let query = args{"query"}.getStr()
    if query.len == 0:
        return %*{"error": "Query is required"}
    
    let limit = if args.hasKey("limit"): args["limit"].getInt() else: 50
    
    let db = openIdeasDb()
    let ideas = db.searchIdeas(query, limit = limit)
    
    return %*{
        "success": true,
        "query": query,
        "count": ideas.len,
        "ideas": ideasToJson(ideas)
    }

proc newSearchIdeasTool*(): Tool =
    Tool(
        name: "search_ideas",
        description: "Search ideas by keyword across content, notes, and tags",
        parameters: %*{
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search term to look for"
                },
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 100,
                    "default": 50,
                    "description": "Maximum number of results"
                }
            }
        },
        handler: searchIdeasHandler
    )

# -----------------------------------------------------------------------------
# Tool: Update Idea
# -----------------------------------------------------------------------------

proc updateIdeaHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    let db = openIdeasDb()
    
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isNone:
        return %*{"error": &"Idea #{id} not found"}
    
    var idea = ideaOpt.get()
    var modified = false
    
    if args.hasKey("content"):
        idea.content = args["content"].getStr()
        modified = true
    
    if args.hasKey("link"):
        let linkStr = args["link"].getStr()
        idea.link = if linkStr.len > 0: some(linkStr) else: none(string)
        if linkStr.len > 0:
            idea.linkTitle = fetchLinkTitle(linkStr)
        modified = true
    
    if args.hasKey("notes"):
        let notesStr = args["notes"].getStr()
        idea.notes = if notesStr.len > 0: some(notesStr) else: none(string)
        modified = true
    
    if args.hasKey("tags"):
        var tags: seq[string] = @[]
        for tag in args["tags"]:
            tags.add tag.getStr()
        idea.tags = tags.join(",")
        modified = true
    
    if args.hasKey("priority"):
        idea.priority = args["priority"].getInt()
        modified = true
    
    if args.hasKey("starred"):
        idea.starred = args["starred"].getBool()
        modified = true
    
    if modified:
        db.updateIdea(idea)
        return %*{
            "success": true,
            "message": &"Updated idea #{id}",
            "idea": ideaToJson(idea)
        }
    else:
        return %*{
            "success": false,
            "message": "No fields to update",
            "idea": ideaToJson(idea)
        }

proc newUpdateIdeaTool*(): Tool =
    Tool(
        name: "update_idea",
        description: "Update an existing idea's fields (content, link, notes, tags, priority, starred)",
        parameters: %*{
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {
                    "type": "integer",
                    "description": "The idea ID to update"
                },
                "content": {
                    "type": "string",
                    "description": "New content text"
                },
                "link": {
                    "type": "string",
                    "description": "New URL reference (use empty string to remove)"
                },
                "notes": {
                    "type": "string",
                    "description": "New notes (use empty string to remove)"
                },
                "tags": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "New tags (replaces existing)"
                },
                "priority": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 3,
                    "description": "New priority level"
                },
                "starred": {
                    "type": "boolean",
                    "description": "Set starred status"
                }
            }
        },
        handler: updateIdeaHandler
    )

# -----------------------------------------------------------------------------
# Tool: Delete Idea
# -----------------------------------------------------------------------------

proc deleteIdeaHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    let db = openIdeasDb()
    
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isNone:
        return %*{"error": &"Idea #{id} not found"}
    
    db.deleteIdea(id)
    
    return %*{
        "success": true,
        "message": &"Deleted idea #{id}"
    }

proc newDeleteIdeaTool*(): Tool =
    Tool(
        name: "delete_idea",
        description: "Permanently delete an idea by ID (use with caution)",
        parameters: %*{
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {
                    "type": "integer",
                    "description": "The idea ID to delete"
                }
            }
        },
        handler: deleteIdeaHandler
    )

# -----------------------------------------------------------------------------
# Tool: Mark Idea Done
# -----------------------------------------------------------------------------

proc markIdeaDoneHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    let db = openIdeasDb()
    
    if db.markDone(id):
        return %*{
            "success": true,
            "message": &"Marked idea #{id} as done"
        }
    else:
        return %*{"error": &"Idea #{id} not found"}

proc newMarkIdeaDoneTool*(): Tool =
    Tool(
        name: "mark_idea_done",
        description: "Mark an idea as completed/done",
        parameters: %*{
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {
                    "type": "integer",
                    "description": "The idea ID to mark as done"
                }
            }
        },
        handler: markIdeaDoneHandler
    )

# -----------------------------------------------------------------------------
# Tool: Archive Idea
# -----------------------------------------------------------------------------

proc archiveIdeaHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    let db = openIdeasDb()
    
    if db.archiveIdea(id):
        return %*{
            "success": true,
            "message": &"Archived idea #{id}"
        }
    else:
        return %*{"error": &"Idea #{id} not found"}

proc newArchiveIdeaTool*(): Tool =
    Tool(
        name: "archive_idea",
        description: "Archive an idea (hides from active list but keeps it)",
        parameters: %*{
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {
                    "type": "integer",
                    "description": "The idea ID to archive"
                }
            }
        },
        handler: archiveIdeaHandler
    )

# -----------------------------------------------------------------------------
# Tool: Unarchive Idea
# -----------------------------------------------------------------------------

proc unarchiveIdeaHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    let db = openIdeasDb()
    
    if db.unarchiveIdea(id):
        return %*{
            "success": true,
            "message": &"Restored idea #{id} from archive"
        }
    else:
        return %*{"error": &"Idea #{id} not found"}

proc newUnarchiveIdeaTool*(): Tool =
    Tool(
        name: "unarchive_idea",
        description: "Restore an archived idea to active status",
        parameters: %*{
            "type": "object",
            "required": ["id"],
            "properties": {
                "id": {
                    "type": "integer",
                    "description": "The idea ID to unarchive"
                }
            }
        },
        handler: unarchiveIdeaHandler
    )

# -----------------------------------------------------------------------------
# Tool: Get Random Idea
# -----------------------------------------------------------------------------

proc randomIdeaHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let db = openIdeasDb()
    
    let tag = if args.hasKey("tag") and args["tag"].getStr().len > 0: 
        some(args["tag"].getStr()) 
    else: 
        none(string)
    
    let ideaOpt = db.getRandomIdea(tag)
    
    if ideaOpt.isNone:
        if tag.isSome:
            return %*{"error": &"No active ideas found with tag '{tag.get()}'"}
        else:
            return %*{"error": "No active ideas found"}
    
    return %*{
        "success": true,
        "idea": ideaToJson(ideaOpt.get())
    }

proc newRandomIdeaTool*(): Tool =
    Tool(
        name: "random_idea",
        description: "Get a random active idea (optionally filtered by tag)",
        parameters: %*{
            "type": "object",
            "properties": {
                "tag": {
                    "type": "string",
                    "description": "Optional tag to filter by"
                }
            }
        },
        handler: randomIdeaHandler
    )

# -----------------------------------------------------------------------------
# Tool: Get Idea Stats
# -----------------------------------------------------------------------------

proc ideaStatsHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let db = openIdeasDb()
    let stats = db.getStats()
    
    return %*{
        "success": true,
        "stats": {
            "total": stats.total,
            "active": stats.active,
            "done": stats.done,
            "archived": stats.archived
        }
    }

proc newIdeaStatsTool*(): Tool =
    Tool(
        name: "idea_stats",
        description: "Get statistics about your ideas (total, active, done, archived)",
        parameters: %*{
            "type": "object",
            "properties": {}
        },
        handler: ideaStatsHandler
    )

# -----------------------------------------------------------------------------
# Tool: List Tags
# -----------------------------------------------------------------------------

proc listTagsHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let db = openIdeasDb()
    let tags = db.getAllTags()
    
    return %*{
        "success": true,
        "count": tags.len,
        "tags": tags
    }

proc newListTagsTool*(): Tool =
    Tool(
        name: "list_idea_tags",
        description: "List all unique tags used across ideas",
        parameters: %*{
            "type": "object",
            "properties": {}
        },
        handler: listTagsHandler
    )

# -----------------------------------------------------------------------------
# Ideas Toolkit
# -----------------------------------------------------------------------------

proc IdeasToolkit*(): Toolkit =
    ## Complete toolkit for ideas management
    result = newToolkit("ideas", "Personal idea capture and management tools")
    
    result.add newCreateIdeaTool()
    result.add newListIdeasTool()
    result.add newGetIdeaTool()
    result.add newSearchIdeasTool()
    result.add newUpdateIdeaTool()
    result.add newDeleteIdeaTool()
    result.add newMarkIdeaDoneTool()
    result.add newArchiveIdeaTool()
    result.add newUnarchiveIdeaTool()
    result.add newRandomIdeaTool()
    result.add newIdeaStatsTool()
    result.add newListTagsTool()
