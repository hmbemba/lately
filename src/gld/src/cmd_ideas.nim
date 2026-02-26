##
## Ideas command handler for GLD CLI
##
## Usage:
##   gld ideas add "My idea" --link https://... --notes "..." --tags work,coding
##   gld ideas                    # List active ideas
##   gld ideas --all              # Show all (including done/archived)
##   gld ideas --done             # Show completed
##   gld ideas --tag work         # Filter by tag
##   gld ideas --starred          # Show only starred
##   gld ideas search "keyword"   # Search content and notes
##   gld ideas show 5             # Show idea #5 details
##   gld ideas edit 5 --content "New text"  # Edit fields
##   gld ideas done 5             # Mark as done
##   gld ideas archive 5          # Archive idea
##   gld ideas unarchive 5        # Unarchive idea
##   gld ideas delete 5           # Permanently delete
##   gld ideas random             # Pick random idea
##   gld ideas random --tag work  # Random from tag
##   gld ideas tags               # List all tags
##   gld ideas stats              # Show statistics
##   gld ideas export --json      # Export to JSON
##   gld ideas export --markdown  # Export to Markdown
##

import
    std/[
        strformat
        ,strutils
        ,sequtils
        ,options
        ,os
        ,json
    ]

import
    termui

import
    ideas_db

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

proc pickArg(args: seq[string], key: string): Option[string] =
    ## Extract single value for flag
    ## Supports: --key=value, --key value
    
    let prefix = "--" & key
    let prefixEq = prefix & "="
    
    for i, arg in args:
        if arg.startsWith(prefixEq):
            return some(arg[prefixEq.len .. ^1])
        elif arg == prefix:
            if i + 1 < args.len and not args[i + 1].startsWith("--"):
                return some(args[i + 1])
    
    return none(string)

proc pickArgMulti(args: seq[string], key: string): seq[string] =
    ## Collect all values for repeated flag
    let prefix = "--" & key & "="
    let prefixSpace = "--" & key
    
    for i, arg in args:
        if arg.startsWith(prefix):
            result.add(arg[prefix.len .. ^1])
        elif arg == prefixSpace:
            if i + 1 < args.len and not args[i + 1].startsWith("--"):
                result.add(args[i + 1])

proc hasFlag(args: seq[string], key: string): bool =
    ## Check if flag exists
    result = "--" & key in args

proc getPositionalText(args: seq[string]): Option[string] =
    ## Get first non-flag argument
    for arg in args:
        if not arg.startsWith("-"):
            return some(arg)
    return none(string)

proc parseTags(tagStr: string): seq[string] =
    ## Parse comma-separated tags
    result = tagStr.split(",").mapIt(it.strip().toLowerAscii())
    result = result.filterIt(it.len > 0)

proc formatIdeaLine(idea: Idea): string =
    ## Format idea for list view
    let statusIcon = case idea.status:
        of isDone: "✓"
        of isArchived: "~"
        of isActive: "•"
    
    let starIcon = if idea.starred: "★" else: " "
    let priorityIcon = case idea.priority:
        of 3: "▲"
        of 2: "◆"
        of 1: "○"
        else: " "
    
    let tagStr = if idea.tags.len > 0: " [" & idea.tags.split(",")[0].strip() & "]" else: ""
    let content = if idea.content.len > 50: idea.content[0..49] & "..." else: idea.content
    
    return &"  {statusIcon}{starIcon}{priorityIcon} #{idea.id}: {content}{tagStr}"

proc printIdeaDetail(idea: Idea) =
    ## Print full idea details
    echo ""
    
    let statusStr = case idea.status:
        of isActive: "Active"
        of isDone: "Done ✓"
        of isArchived: "Archived ~"
    
    let starStr = if idea.starred: " ★ Starred" else: ""
    let priorityStr = case idea.priority:
        of 3: " 🔴 High"
        of 2: " 🟡 Medium"
        of 1: " 🟢 Low"
        else: ""
    
    echo ""
    echo &"  ── Idea #{idea.id} ──"
    termuiLabel("Status:", statusStr & starStr & priorityStr)
    echo ""
    
    echo "  " & idea.content
    echo ""
    
    if idea.link.isSome:
        let displayTitle = if idea.linkTitle.isSome: 
            idea.linkTitle.get() 
        else: 
            idea.link.get()
        termuiLabel("Link:", &"{displayTitle}")
        termuiLabel("URL:", idea.link.get())
        echo ""
    
    if idea.notes.isSome:
        termuiLabel("Notes:", "")
        for line in idea.notes.get().splitLines():
            echo "    " & line
        echo ""
    
    if idea.tags.len > 0:
        let tagStr = idea.tags.split(",").mapIt("#" & it.strip()).join(" ")
        termuiLabel("Tags:", tagStr)
    
    termuiLabel("Created:", idea.createdAt.format("yyyy-MM-dd HH:mm"))
    if idea.updatedAt != idea.createdAt:
        termuiLabel("Updated:", idea.updatedAt.format("yyyy-MM-dd HH:mm"))
    echo ""

proc printIdeasHelp*() =
    ## Print help for ideas command
    echo ""
    echo "  💡 GLD IDEAS - Personal Idea Database"
    echo "  ====================================="
    echo ""
    echo "  Capture and manage your ideas, notes, and links."
    echo "  Stored locally in SQLite at ~/.gld/gld.db"
    echo ""
    echo "  COMMANDS"
    echo ""
    echo "    gld ideas add \"<content>\" [options]"
    echo "      --link <url>         Associate a URL"
    echo "      --notes <text>       Longer notes/description"
    echo "      --tags <tags>        Comma-separated tags (e.g., work,coding)"
    echo "      --priority <0-3>     Priority level (3=highest)"
    echo "      --starred            Mark as starred"
    echo ""
    echo "    gld ideas                    # List active ideas"
    echo "    gld ideas --all              # Show all statuses"
    echo "    gld ideas --done             # Show completed"
    echo "    gld ideas --tag <tag>        # Filter by tag"
    echo "    gld ideas --starred          # Show only starred"
    echo "    gld ideas search <term>      # Search content & notes"
    echo ""
    echo "    gld ideas show <id>          # Show full details"
    echo "    gld ideas edit <id> [opts]   # Edit idea fields"
    echo "    gld ideas done <id>          # Mark as done"
    echo "    gld ideas archive <id>       # Archive idea"
    echo "    gld ideas unarchive <id>     # Restore from archive"
    echo "    gld ideas delete <id>        # Permanently delete"
    echo ""
    echo "    gld ideas random             # Pick random active idea"
    echo "    gld ideas random --tag work  # Random from tag"
    echo "    gld ideas tags               # List all tags"
    echo "    gld ideas stats              # Show statistics"
    echo ""
    echo "    gld ideas export --json      # Export to JSON"
    echo "    gld ideas export --markdown  # Export to Markdown"
    echo ""
    echo "  EXAMPLES"
    echo ""
    echo "    $ gld ideas add \"Build a CLI tool\" --tags coding,nim --starred"
    echo "    $ gld ideas add \"Read article\" --link https://example.com --priority 2"
    echo "    $ gld ideas search \"nim\""
    echo "    $ gld ideas --tag work --starred"
    echo "    $ gld ideas random"
    echo ""

# -----------------------------------------------------------------------------
# Command Handlers
# -----------------------------------------------------------------------------

proc runIdeasAdd*(args: seq[string]) =
    ## Handle 'gld ideas add'
    
    let contentOpt = getPositionalText(args)
    if contentOpt.isNone or contentOpt.get().len == 0:
        echo "❌ Error: Idea content required"
        echo "   Usage: gld ideas add \"<your idea>\""
        return
    
    let content = contentOpt.get()
    let link = pickArg(args, "link")
    let notes = pickArg(args, "notes")
    let tagsStr = pickArg(args, "tags")
    let priorityStr = pickArg(args, "priority")
    let starred = hasFlag(args, "starred")
    
    var priority = 0
    if priorityStr.isSome:
        try:
            priority = priorityStr.get().parseInt()
            if priority < 0: priority = 0
            if priority > 3: priority = 3
        except:
            priority = 0
    
    let tags = if tagsStr.isSome: parseTags(tagsStr.get()) else: @[]
    
    let db = openIdeasDb()
    
    let idea = db.createIdea(
        content = content
        ,link = link
        ,notes = notes
        ,tags = tags
        ,priority = priority
        ,starred = starred
    )
    
    echo &"✓ Added idea #{idea.id}"
    if idea.linkTitle.isSome:
        echo &"  Found link title: {idea.linkTitle.get()}"

proc runIdeasList*(args: seq[string]) =
    ## Handle 'gld ideas' list command
    
    let allFlag = hasFlag(args, "all")
    let doneFlag = hasFlag(args, "done")
    let archivedFlag = hasFlag(args, "archived")
    let starredFlag = hasFlag(args, "starred")
    let tagOpt = pickArg(args, "tag")
    
    var status: Option[IdeaStatus]
    if allFlag:
        status = none(IdeaStatus)
    elif doneFlag:
        status = some(isDone)
    elif archivedFlag:
        status = some(isArchived)
    else:
        status = some(isActive)
    
    let db = openIdeasDb()
    
    let ideas = db.listIdeas(
        status = status
        ,tag = tagOpt
        ,starredOnly = starredFlag
        ,limit = 100
    )
    
    if ideas.len == 0:
        echo "No ideas found."
        echo "Add one with: gld ideas add \"<your idea>\""
        return
    
    let statusLabel = if status.isSome: $status.get() else: "all"
    echo ""
    echo &"  💡 {ideas.len} {statusLabel} idea(s):"
    echo ""
    
    for idea in ideas:
        echo formatIdeaLine(idea)
    
    echo ""
    echo "  Use 'gld ideas show <id>' for details"

proc runIdeasSearch*(args: seq[string]) =
    ## Handle 'gld ideas search <term>'
    
    let termOpt = getPositionalText(args)
    if termOpt.isNone or termOpt.get().len == 0:
        echo "❌ Error: Search term required"
        echo "   Usage: gld ideas search \"<keyword>\""
        return
    
    let db = openIdeasDb()
    
    let ideas = db.searchIdeas(termOpt.get())
    
    if ideas.len == 0:
        echo &"No ideas found matching '{termOpt.get()}'"
        return
    
    echo ""
    echo &"  🔍 {ideas.len} result(s) for '{termOpt.get()}':"
    echo ""
    
    for idea in ideas:
        echo formatIdeaLine(idea)
    echo ""

proc runIdeasShow*(args: seq[string]) =
    ## Handle 'gld ideas show <id>'
    
    let idOpt = getPositionalText(args)
    if idOpt.isNone:
        echo "❌ Error: Idea ID required"
        return
    
    var id: int
    try:
        id = idOpt.get().parseInt()
    except:
        echo &"❌ Error: Invalid ID '{idOpt.get()}'"
        return
    
    let db = openIdeasDb()
    
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isNone:
        echo &"❌ Idea #{id} not found"
        return
    
    printIdeaDetail(ideaOpt.get())

proc runIdeasEdit*(args: seq[string]) =
    ## Handle 'gld ideas edit <id>'
    
    # First arg is ID, rest are flags
    var idArg = ""
    var flagArgs: seq[string] = @[]
    
    for i, arg in args:
        if i == 0 and not arg.startsWith("--"):
            idArg = arg
        else:
            flagArgs.add(arg)
    
    if idArg.len == 0:
        echo "❌ Error: Idea ID required"
        echo "   Usage: gld ideas edit <id> [--content \"new text\"] [--priority 2]"
        return
    
    var id: int
    try:
        id = idArg.parseInt()
    except:
        echo &"❌ Error: Invalid ID '{idArg}'"
        return
    
    let db = openIdeasDb()
    
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isNone:
        echo &"❌ Idea #{id} not found"
        return
    
    var idea = ideaOpt.get()
    var modified = false
    
    # Apply edits
    let contentOpt = pickArg(flagArgs, "content")
    if contentOpt.isSome:
        idea.content = contentOpt.get()
        modified = true
    
    let linkOpt = pickArg(flagArgs, "link")
    if linkOpt.isSome:
        idea.link = linkOpt
        # Try to fetch new title
        idea.linkTitle = fetchLinkTitle(linkOpt.get())
        modified = true
    
    let notesOpt = pickArg(flagArgs, "notes")
    if notesOpt.isSome:
        idea.notes = notesOpt
        modified = true
    
    let tagsOpt = pickArg(flagArgs, "tags")
    if tagsOpt.isSome:
        idea.tags = parseTags(tagsOpt.get()).join(",")
        modified = true
    
    let priorityOpt = pickArg(flagArgs, "priority")
    if priorityOpt.isSome:
        try:
            idea.priority = priorityOpt.get().parseInt()
            if idea.priority < 0: idea.priority = 0
            if idea.priority > 3: idea.priority = 3
            modified = true
        except:
            discard
    
    let starredOpt = pickArg(flagArgs, "starred")
    if starredOpt.isSome:
        idea.starred = starredOpt.get().toLowerAscii() in ["true", "1", "yes"]
        modified = true
    
    if modified:
        db.updateIdea(idea)
        echo &"✓ Updated idea #{id}"
    else:
        echo "No changes specified"
        echo "Use --content, --link, --notes, --tags, --priority, or --starred"

proc runIdeasDone*(args: seq[string]) =
    ## Handle 'gld ideas done <id>'
    
    let idOpt = getPositionalText(args)
    if idOpt.isNone:
        echo "❌ Error: Idea ID required"
        return
    
    var id: int
    try:
        id = idOpt.get().parseInt()
    except:
        echo &"❌ Error: Invalid ID '{idOpt.get()}'"
        return
    
    let db = openIdeasDb()
    
    if db.markDone(id):
        echo &"✓ Marked idea #{id} as done"
    else:
        echo &"❌ Idea #{id} not found"

proc runIdeasArchive*(args: seq[string], unarchive: bool = false) =
    ## Handle archive/unarchive
    
    let idOpt = getPositionalText(args)
    if idOpt.isNone:
        echo &"❌ Error: Idea ID required"
        return
    
    var id: int
    try:
        id = idOpt.get().parseInt()
    except:
        echo &"❌ Error: Invalid ID '{idOpt.get()}'"
        return
    
    let db = openIdeasDb()
    
    if unarchive:
        if db.unarchiveIdea(id):
            echo &"✓ Restored idea #{id}"
        else:
            echo &"❌ Idea #{id} not found"
    else:
        if db.archiveIdea(id):
            echo &"✓ Archived idea #{id}"
        else:
            echo &"❌ Idea #{id} not found"

proc runIdeasDelete*(args: seq[string]) =
    ## Handle 'gld ideas delete <id>'
    
    let idOpt = getPositionalText(args)
    if idOpt.isNone:
        echo "❌ Error: Idea ID required"
        return
    
    var id: int
    try:
        id = idOpt.get().parseInt()
    except:
        echo &"❌ Error: Invalid ID '{idOpt.get()}'"
        return
    
    let db = openIdeasDb()
    
    let ideaOpt = db.getIdea(id)
    if ideaOpt.isNone:
        echo &"❌ Idea #{id} not found"
        return
    
    let idea = ideaOpt.get()
    echo &"⚠️  About to permanently delete idea #{id}:"
    echo &"   \"{idea.content}\""
    echo ""
    
    # Simple confirmation
    echo "Type 'yes' to confirm:"
    let confirm = readLine(stdin)
    if confirm.toLowerAscii() == "yes":
        db.deleteIdea(id)
        echo &"✓ Deleted idea #{id}"
    else:
        echo "Cancelled"

proc runIdeasRandom*(args: seq[string]) =
    ## Handle 'gld ideas random'
    
    let tagOpt = pickArg(args, "tag")
    
    let db = openIdeasDb()
    
    let ideaOpt = db.getRandomIdea(tagOpt)
    if ideaOpt.isNone:
        if tagOpt.isSome:
            echo &"No active ideas found with tag '{tagOpt.get()}'"
        else:
            echo "No active ideas found"
        return
    
    printIdeaDetail(ideaOpt.get())

proc runIdeasTags*(args: seq[string]) =
    ## Handle 'gld ideas tags'
    
    let db = openIdeasDb()
    
    let tags = db.getAllTags()
    
    if tags.len == 0:
        echo "No tags found."
        return
    
    echo ""
    echo &"  {tags.len} tag(s):"
    echo ""
    
    for tag in tags:
        echo &"    #{tag}"
    echo ""

proc runIdeasStats*(args: seq[string]) =
    ## Handle 'gld ideas stats'
    
    let db = openIdeasDb()
    
    let stats = db.getStats()
    
    echo ""
    echo "  📊 Ideas Statistics"
    echo ""
    termuiLabel("Total:", $stats.total)
    termuiLabel("Active:", $stats.active)
    termuiLabel("Done:", $stats.done)
    termuiLabel("Archived:", $stats.archived)
    echo ""

proc runIdeasExport*(args: seq[string]) =
    ## Handle 'gld ideas export'
    
    let jsonFlag = hasFlag(args, "json")
    let markdownFlag = hasFlag(args, "markdown")
    let allFlag = hasFlag(args, "all")
    
    let db = openIdeasDb()
    
    let status = if allFlag: none(IdeaStatus) else: some(isActive)
    
    if markdownFlag:
        let md = db.exportToMarkdown(status)
        echo md
    else:
        # Default to JSON
        let json = db.exportToJson(status)
        echo json

# -----------------------------------------------------------------------------
# Main Entry Point
# -----------------------------------------------------------------------------

proc runIdeas*(args: seq[string]) =
    ## Main entry for 'gld ideas' command
    
    if args.len == 0:
        # Default: list active ideas
        runIdeasList(@[])
        return
    
    let subcommand = args[0].toLowerAscii()
    let subArgs = args[1..^1]
    
    case subcommand:
        of "add":
            runIdeasAdd(subArgs)
        of "show", "view":
            runIdeasShow(subArgs)
        of "edit", "update":
            runIdeasEdit(subArgs)
        of "done", "complete", "finish":
            runIdeasDone(subArgs)
        of "archive":
            runIdeasArchive(subArgs, unarchive = false)
        of "unarchive", "restore":
            runIdeasArchive(subArgs, unarchive = true)
        of "delete", "remove", "rm":
            runIdeasDelete(subArgs)
        of "search", "find", "s":
            runIdeasSearch(subArgs)
        of "random", "r":
            runIdeasRandom(subArgs)
        of "tags", "tag":
            runIdeasTags(subArgs)
        of "stats", "stat":
            runIdeasStats(subArgs)
        of "export", "ex":
            runIdeasExport(subArgs)
        of "help", "--help", "-h":
            printIdeasHelp()
        else:
            # Check if it's a flag-based list command
            if subcommand.startsWith("--"):
                runIdeasList(args)
            else:
                echo &"❓ Unknown subcommand: {subcommand}"
                echo ""
                printIdeasHelp()
