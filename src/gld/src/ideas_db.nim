##
## Ideas Database - Personal idea capture system
##
## Uses debby ORM for SQLite storage
##

import
    std/[
        os
        ,times
        ,strutils
        ,sequtils
        ,algorithm
        ,strformat
        ,options
        ,random
        ,httpclient
        ,uri
    ]

import
    debby/sqlite
    ,jsony

import
    paths

# -----------------------------------------------------------------------------
# Types
# -----------------------------------------------------------------------------

type
    IdeaStatus* = enum
        isActive = "active"
        isDone = "done"
        isArchived = "archived"
    
    Idea* = ref object
        id*: int                    ## Primary key (required by debby)
        content*: string            ## Main idea text
        link*: Option[string]       ## Optional URL reference
        linkTitle*: Option[string]  ## Fetched title from link
        notes*: Option[string]      ## Optional longer notes
        tags*: string               ## Comma-separated tags
        status*: IdeaStatus
        priority*: int              ## 0-3
        starred*: bool
        createdAt*: string          ## ISO format datetime
        updatedAt*: string          ## ISO format datetime

# -----------------------------------------------------------------------------
# Database Connection
# -----------------------------------------------------------------------------

proc dbPath*(): string =
    ## Path to the SQLite database
    result = gldDir() / "gld.db"

proc openIdeasDb*(): Db =
    ## Open database connection and ensure tables exist
    result = openDatabase(dbPath())
    
    # Create table if not exists (ignore error if already exists)
    try:
        result.createTable(Idea)
    except:
        # Table already exists, that's fine
        discard
    
    # Create indexes for common queries
    try:
        result.createIndex(Idea, "status")
        result.createIndex(Idea, "tags")
        result.createIndex(Idea, "starred")
    except:
        # Indexes might already exist, ignore errors
        discard

# -----------------------------------------------------------------------------
# Link Title Fetching
# -----------------------------------------------------------------------------

proc fetchLinkTitle*(url: string): Option[string] =
    ## Try to fetch the title from a URL
    ## Returns none if failed (never crashes)
    if url.len == 0 or not url.startsWith("http"):
        return none(string)
    
    try:
        let client = newHttpClient(timeout = 5000)  # 5 second timeout
        defer: client.close()
        
        let response = client.get(url)
        if response.code.int >= 200 and response.code.int < 300:
            let html = response.body
            
            # Simple title extraction - look for <title> tag
            let titleStart = html.find("<title>")
            let titleEnd = html.find("</title>")
            
            if titleStart >= 0 and titleEnd > titleStart:
                var title = html[titleStart + 7 ..< titleEnd]
                # Decode basic HTML entities
                title = title.replace("&amp;", "&")
                title = title.replace("&lt;", "<")
                title = title.replace("&gt;", ">")
                title = title.replace("&quot;", "\"")
                title = title.strip()
                
                if title.len > 0 and title.len < 200:
                    return some(title)
    except:
        # Silently ignore any errors (network, parsing, etc.)
        discard
    
    return none(string)

# -----------------------------------------------------------------------------
# CRUD Operations
# -----------------------------------------------------------------------------

proc createIdea*(
    db: Db
    ,content: string
    ,link: Option[string] = none(string)
    ,notes: Option[string] = none(string)
    ,tags: seq[string] = @[]
    ,priority: int = 0
    ,starred: bool = false
): Idea =
    ## Create a new idea
    
    # Try to fetch link title if link provided
    var linkTitle = none(string)
    if link.isSome:
        linkTitle = fetchLinkTitle(link.get())
    
    let nowStr = now().format("yyyy-MM-dd HH:mm:ss")
    var idea = Idea(
        id: 0,  # Will be set by debby on insert
        content: content,
        link: link,
        linkTitle: linkTitle,
        notes: notes,
        tags: tags.join(","),
        status: isActive,
        priority: priority,
        starred: starred,
        createdAt: nowStr,
        updatedAt: nowStr
    )
    
    db.insert(idea)
    return idea

proc getIdea*(db: Db, id: int): Option[Idea] =
    ## Get a single idea by ID
    try:
        return some(db.get(Idea, id))
    except:
        return none(Idea)

proc updateIdea*(db: Db, idea: Idea) =
    ## Update an existing idea
    idea.updatedAt = now().format("yyyy-MM-dd HH:mm:ss")
    db.update(idea)

proc deleteIdea*(db: Db, id: int) =
    ## Permanently delete an idea
    let idea = db.get(Idea, id)
    db.delete(idea)

# -----------------------------------------------------------------------------
# Query Operations
# -----------------------------------------------------------------------------

proc listIdeas*(
    db: Db
    ,status: Option[IdeaStatus] = some(isActive)
    ,tag: Option[string] = none(string)
    ,starredOnly: bool = false
    ,limit: int = 50
): seq[Idea] =
    ## List ideas with optional filters
    
    var query = "SELECT * FROM Idea WHERE 1=1"
    var params: seq[string] = @[]
    
    if status.isSome:
        query.add " AND status = ?"
        params.add $status.get()
    
    if starredOnly:
        query.add " AND starred = 1"
    
    if tag.isSome:
        # Simple tag matching - checks if tag is in comma-separated list
        query.add " AND (',' || tags || ',') LIKE ?"
        params.add "%," & tag.get() & ",%"
    
    query.add " ORDER BY priority DESC, created_at DESC"
    query.add " LIMIT " & $limit
    
    # Execute query with appropriate parameters
    if params.len == 0:
        result = db.query(Idea, query)
    elif params.len == 1:
        result = db.query(Idea, query, params[0])
    elif params.len == 2:
        result = db.query(Idea, query, params[0], params[1])
    else:
        result = db.query(Idea, query, params[0], params[1], params[2])

proc searchIdeas*(
    db: Db
    ,searchTerm: string
    ,limit: int = 50
): seq[Idea] =
    ## Search across content, notes, and tags
    
    let term = "%" & searchTerm.toLowerAscii() & "%"
    let query = """
        SELECT * FROM Idea 
        WHERE (LOWER(content) LIKE ? OR LOWER(notes) LIKE ? OR LOWER(tags) LIKE ?)
        AND status != 'archived'
        ORDER BY priority DESC, created_at DESC
        LIMIT ?
    """
    
    result = db.query(Idea, query, term, term, term, $limit)

proc getRandomIdea*(
    db: Db
    ,tag: Option[string] = none(string)
): Option[Idea] =
    ## Get a random active idea
    
    var query = "SELECT * FROM Idea WHERE status = 'active'"
    var params: seq[string] = @[]
    
    if tag.isSome:
        query.add " AND (',' || tags || ',') LIKE ?"
        params.add "%," & tag.get() & ",%"
    
    query.add " ORDER BY RANDOM() LIMIT 1"
    
    let ideas = if params.len == 0:
        db.query(Idea, query)
    else:
        db.query(Idea, query, params[0])
    if ideas.len > 0:
        return some(ideas[0])
    return none(Idea)

proc getAllTags*(db: Db): seq[string] =
    ## Get all unique tags used across ideas
    
    let query = "SELECT DISTINCT tags FROM Idea WHERE tags != ''"
    let rows = db.query(query)
    
    var tagSet: seq[string] = @[]
    for row in rows:
        if row.len > 0:
            let tags = row[0].split(",")
            for tag in tags:
                let trimmed = tag.strip()
                if trimmed.len > 0 and trimmed notin tagSet:
                    tagSet.add(trimmed)
    
    return tagSet.sorted()

# -----------------------------------------------------------------------------
# Status Operations
# -----------------------------------------------------------------------------

proc markDone*(db: Db, id: int): bool =
    ## Mark an idea as done
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isSome:
        var idea = ideaOpt.get()
        idea.status = isDone
        db.updateIdea(idea)
        return true
    return false

proc archiveIdea*(db: Db, id: int): bool =
    ## Archive an idea
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isSome:
        var idea = ideaOpt.get()
        idea.status = isArchived
        db.updateIdea(idea)
        return true
    return false

proc unarchiveIdea*(db: Db, id: int): bool =
    ## Unarchive an idea (back to active)
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isSome:
        var idea = ideaOpt.get()
        idea.status = isActive
        db.updateIdea(idea)
        return true
    return false

proc toggleStarred*(db: Db, id: int): Option[bool] =
    ## Toggle starred status, returns new state
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isSome:
        var idea = ideaOpt.get()
        idea.starred = not idea.starred
        db.updateIdea(idea)
        return some(idea.starred)
    return none(bool)

# -----------------------------------------------------------------------------
# Export Operations
# -----------------------------------------------------------------------------

proc exportToJson*(db: Db, status: Option[IdeaStatus] = none(IdeaStatus)): string =
    ## Export ideas to JSON
    
    var ideas: seq[Idea]
    if status.isSome:
        ideas = db.listIdeas(status = status)
    else:
        ideas = db.query(Idea, "SELECT * FROM Idea ORDER BY created_at DESC")
    
    return ideas.toJson()

proc exportToMarkdown*(db: Db, status: Option[IdeaStatus] = none(IdeaStatus)): string =
    ## Export ideas to Markdown
    
    var ideas: seq[Idea]
    if status.isSome:
        ideas = db.listIdeas(status = status)
    else:
        ideas = db.query(Idea, "SELECT * FROM Idea ORDER BY priority DESC, created_at DESC")
    
    var lines: seq[string] = @["# Ideas\n"]
    
    for idea in ideas:
        let statusIcon = case idea.status:
            of isDone: "[x]"
            of isArchived: "[~]"
            of isActive: "[ ]"
        
        let starIcon = if idea.starred: "⭐ " else: ""
        let priorityIcon = case idea.priority:
            of 3: "🔴 "
            of 2: "🟡 "
            of 1: "🟢 "
            else: ""
        
        lines.add(&"## {statusIcon} {starIcon}{priorityIcon}{idea.id}: {idea.content}\n")
        
        if idea.link.isSome:
            let title = if idea.linkTitle.isSome: idea.linkTitle.get() else: idea.link.get()
            lines.add(&"**Link:** [{title}]({idea.link.get()})\n")
        
        if idea.tags.len > 0:
            let tagStr = idea.tags.split(",").mapIt("`" & it.strip() & "`").join(" ")
            lines.add(&"**Tags:** {tagStr}\n")
        
        if idea.notes.isSome:
            lines.add(&"\n{idea.notes.get()}\n")
        
        lines.add(&"\n*Created: {idea.createdAt}*\n")
        lines.add("\n---\n")
    
    return lines.join("\n")

# -----------------------------------------------------------------------------
# Stats
# -----------------------------------------------------------------------------

proc getStats*(db: Db): tuple[total: int, active: int, done: int, archived: int] =
    ## Get idea counts by status
    
    let total = db.query("SELECT COUNT(*) FROM Idea")[0][0].parseInt()
    let active = db.query("SELECT COUNT(*) FROM Idea WHERE status = 'active'")[0][0].parseInt()
    let done = db.query("SELECT COUNT(*) FROM Idea WHERE status = 'done'")[0][0].parseInt()
    let archived = db.query("SELECT COUNT(*) FROM Idea WHERE status = 'archived'")[0][0].parseInt()
    
    return (total: total, active: active, done: done, archived: archived)
