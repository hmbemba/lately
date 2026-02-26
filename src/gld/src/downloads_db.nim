##
## Downloads Database - Track all media downloads
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
        ,json
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
    DownloadStatus* = enum
        dsPending = "pending"
        dsDownloading = "downloading"
        dsCompleted = "completed"
        dsFailed = "failed"
        dsCancelled = "cancelled"

    DownloadContentType* = enum
        dctVideo = "video"
        dctAudio = "audio"
        dctImage = "image"
        dctDocument = "document"
        dctUnknown = "unknown"

    DownloadPlatform* = enum
        dpYouTube = "youtube"
        dpTikTok = "tiktok"
        dpInstagram = "instagram"
        dpTwitter = "twitter"
        dpFacebook = "facebook"
        dpLinkedIn = "linkedin"
        dpBlueSky = "bluesky"
        dpReddit = "reddit"
        dpGeneric = "generic"

    Download* = ref object
        id*: int                    ## Primary key
        # Source info
        sourceUrl*: string          ## Original URL downloaded from
        platform*: DownloadPlatform ## Which platform it came from
        # File info
        filename*: string           ## Local filename
        originalFilename*: Option[string]  ## Original filename from source
        downloadPath*: string       ## Full local path where saved
        fileSize*: Option[int64]    ## File size in bytes
        contentType*: DownloadContentType  ## video, audio, image, etc.
        mimeType*: Option[string]   ## MIME type if known
        fileExtension*: Option[string]     ## File extension
        # Media metadata
        title*: Option[string]      ## Content title if available
        description*: Option[string]## Content description
        duration*: Option[int]      ## Duration in seconds (for media)
        thumbnailUrl*: Option[string]      ## Preview image URL
        # Download tracking
        status*: DownloadStatus
        startedAt*: Option[string]  ## When download started (ISO datetime)
        completedAt*: Option[string]## When download finished (ISO datetime)
        errorMessage*: Option[string]      ## If failed, error details
        httpStatusCode*: Option[int]       ## HTTP response code
        # Metadata & tags
        metadataJson*: Option[string]      ## Additional JSON metadata
        tags*: string               ## Comma-separated tags for organization
        notes*: Option[string]      ## User notes about this download
        # Audit
        createdAt*: string          ## ISO format datetime
        updatedAt*: string          ## ISO format datetime

# -----------------------------------------------------------------------------
# Database Connection
# -----------------------------------------------------------------------------

proc dbPath*(): string =
    ## Path to the SQLite database
    result = gldDir() / "gld.db"

proc openDownloadsDb*(): Db =
    ## Open database connection and ensure tables exist
    result = openDatabase(dbPath())
    
    # Create table if not exists (ignore error if already exists)
    try:
        result.createTable(Download)
    except:
        # Table already exists, that's fine
        discard
    
    # Create indexes for common queries
    try:
        result.createIndex(Download, "status")
        result.createIndex(Download, "platform")
        result.createIndex(Download, "sourceUrl")
        result.createIndex(Download, "createdAt")
    except:
        # Indexes might already exist, ignore errors
        discard

# -----------------------------------------------------------------------------
# CRUD Operations
# -----------------------------------------------------------------------------

proc recordDownload*(
    db: Db
    ,sourceUrl: string
    ,filename: string
    ,downloadPath: string
    ,platform: DownloadPlatform = dpGeneric
    ,contentType: DownloadContentType = dctUnknown
    ,originalFilename: Option[string] = none(string)
    ,fileSize: Option[int64] = none(int64)
    ,mimeType: Option[string] = none(string)
    ,fileExtension: Option[string] = none(string)
    ,title: Option[string] = none(string)
    ,description: Option[string] = none(string)
    ,duration: Option[int] = none(int)
    ,thumbnailUrl: Option[string] = none(string)
    ,metadataJson: Option[string] = none(string)
    ,tags: seq[string] = @[]
    ,notes: Option[string] = none(string)
): Download =
    ## Record a new download in the database
    let now = now().format("yyyy-MM-dd HH:mm:ss")
    let tagsStr = tags.join(",")
    
    var download = Download(
        id: 0,  # Will be set by debby
        sourceUrl: sourceUrl,
        platform: platform,
        filename: filename,
        originalFilename: originalFilename,
        downloadPath: downloadPath,
        fileSize: fileSize,
        contentType: contentType,
        mimeType: mimeType,
        fileExtension: fileExtension,
        title: title,
        description: description,
        duration: duration,
        thumbnailUrl: thumbnailUrl,
        status: dsPending,
        startedAt: some(now),
        completedAt: none(string),
        errorMessage: none(string),
        httpStatusCode: none(int),
        metadataJson: metadataJson,
        tags: tagsStr,
        notes: notes,
        createdAt: now,
        updatedAt: now
    )
    
    db.insert(download)
    return download

proc getDownload*(db: Db, id: int): Option[Download] =
    ## Get a download by ID
    try:
        return some(db.get(Download, id))
    except:
        return none(Download)

proc getDownloadBySource*(db: Db, sourceUrl: string): Option[Download] =
    ## Get the most recent download by source URL
    let downloads = db.query(Download, 
        "SELECT * FROM Download WHERE sourceUrl = ? ORDER BY createdAt DESC LIMIT 1", 
        sourceUrl)
    if downloads.len > 0:
        return some(downloads[0])
    return none(Download)

proc updateDownload*(db: Db, download: Download) =
    ## Update an existing download
    download.updatedAt = now().format("yyyy-MM-dd HH:mm:ss")
    db.update(download)

proc deleteDownload*(db: Db, id: int): bool =
    ## Delete a download record
    try:
        let download = db.get(Download, id)
        db.delete(download)
        return true
    except:
        return false

# -----------------------------------------------------------------------------
# Status Operations
# -----------------------------------------------------------------------------

proc updateDownloadStatus*(
    db: Db
    ,id: int
    ,status: DownloadStatus
    ,errorMessage: Option[string] = none(string)
    ,httpStatusCode: Option[int] = none(int)
): bool =
    ## Update download status
    let downloadOpt = db.getDownload(id)
    if downloadOpt.isSome:
        var download = downloadOpt.get()
        download.status = status
        download.errorMessage = errorMessage
        download.httpStatusCode = httpStatusCode
        
        if status in [dsCompleted, dsFailed, dsCancelled]:
            download.completedAt = some(now().format("yyyy-MM-dd HH:mm:ss"))
        
        db.updateDownload(download)
        return true
    return false

proc updateDownloadFileInfo*(
    db: Db
    ,id: int
    ,fileSize: Option[int64]
    ,mimeType: Option[string] = none(string)
    ,duration: Option[int] = none(int)
): bool =
    ## Update file info after download completes
    let downloadOpt = db.getDownload(id)
    if downloadOpt.isSome:
        var download = downloadOpt.get()
        download.fileSize = fileSize
        download.mimeType = mimeType
        download.duration = duration
        db.updateDownload(download)
        return true
    return false

# -----------------------------------------------------------------------------
# Query Operations
# -----------------------------------------------------------------------------

proc listDownloads*(
    db: Db
    ,status: Option[DownloadStatus] = none(DownloadStatus)
    ,platform: Option[DownloadPlatform] = none(DownloadPlatform)
    ,contentType: Option[DownloadContentType] = none(DownloadContentType)
    ,tag: Option[string] = none(string)
    ,limit: int = 50
    ,offset: int = 0
): seq[Download] =
    ## List downloads with optional filters
    var query = "SELECT * FROM Download WHERE 1=1"
    var params: seq[string] = @[]
    
    if status.isSome:
        query.add(" AND status = ?")
        params.add($status.get)
    
    if platform.isSome:
        query.add(" AND platform = ?")
        params.add($platform.get)
    
    if contentType.isSome:
        query.add(" AND contentType = ?")
        params.add($contentType.get)
    
    if tag.isSome:
        query.add(" AND (',' || tags || ',') LIKE ?")
        params.add("%," & tag.get & ",%")
    
    query.add(" ORDER BY createdAt DESC")
    query.add(" LIMIT " & $limit & " OFFSET " & $offset)
    
    # Execute query with appropriate parameters
    if params.len == 0:
        result = db.query(Download, query)
    elif params.len == 1:
        result = db.query(Download, query, params[0])
    elif params.len == 2:
        result = db.query(Download, query, params[0], params[1])
    elif params.len == 3:
        result = db.query(Download, query, params[0], params[1], params[2])
    else:
        result = db.query(Download, query, params[0], params[1], params[2], params[3])

proc searchDownloads*(
    db: Db
    ,searchTerm: string
    ,limit: int = 50
): seq[Download] =
    ## Search across title, filename, sourceUrl, description, notes, and tags
    let term = "%" & searchTerm.toLowerAscii() & "%"
    
    let query = """
        SELECT * FROM Download 
        WHERE (LOWER(title) LIKE ? 
           OR LOWER(filename) LIKE ? 
           OR LOWER(sourceUrl) LIKE ? 
           OR LOWER(description) LIKE ? 
           OR LOWER(notes) LIKE ? 
           OR LOWER(tags) LIKE ?)
        ORDER BY createdAt DESC
        LIMIT ?
    """
    
    result = db.query(Download, query, term, term, term, term, term, term, $limit)

proc getDownloadsByDateRange*(
    db: Db
    ,startDate: string
    ,endDate: string
    ,limit: int = 100
): seq[Download] =
    ## Get downloads within a date range (dates in ISO format: yyyy-MM-dd)
    ## Get downloads within a date range
    let query = """
        SELECT * FROM Download 
        WHERE createdAt >= ? AND createdAt < date(?, '+1 day')
        ORDER BY createdAt DESC
        LIMIT ?
    """
    
    result = db.query(Download, query, startDate, endDate, $limit)

proc getAllTags*(db: Db): seq[string] =
    ## Get all unique tags used across downloads
    let query = "SELECT DISTINCT tags FROM Download WHERE tags != ''"
    let rows = db.query(query)
    
    var tagSet: seq[string] = @[]
    for row in rows:
        if row.len > 0:
            let tags = row[0].split(",")
            for tag in tags:
                let trimmed = tag.strip()
                if trimmed.len > 0 and trimmed notin tagSet:
                    tagSet.add(trimmed)
    
    result = tagSet.sorted()

# -----------------------------------------------------------------------------
# Statistics
# -----------------------------------------------------------------------------

proc getStats*(db: Db): tuple[
    total: int
    ,completed: int
    ,failed: int
    ,pending: int
    ,totalSize: int64
    ,byPlatform: seq[tuple[platform: string, count: int]]
] =
    ## Get download statistics
    let totalRow = db.query("SELECT COUNT(*) FROM Download")
    let total = if totalRow.len > 0: parseInt(totalRow[0][0]) else: 0
    
    let completedRow = db.query("SELECT COUNT(*) FROM Download WHERE status = 'completed'")
    let completed = if completedRow.len > 0: parseInt(completedRow[0][0]) else: 0
    
    let failedRow = db.query("SELECT COUNT(*) FROM Download WHERE status = 'failed'")
    let failed = if failedRow.len > 0: parseInt(failedRow[0][0]) else: 0
    
    let pendingRow = db.query("SELECT COUNT(*) FROM Download WHERE status IN ('pending', 'downloading')")
    let pending = if pendingRow.len > 0: parseInt(pendingRow[0][0]) else: 0
    
    let sizeRow = db.query("SELECT COALESCE(SUM(fileSize), 0) FROM Download WHERE status = 'completed'")
    let totalSize = if sizeRow.len > 0: parseBiggestInt(sizeRow[0][0]) else: 0'i64
    
    # Platform breakdown
    var byPlatform: seq[tuple[platform: string, count: int]] = @[]
    let platformRows = db.query("SELECT platform, COUNT(*) as cnt FROM Download GROUP BY platform")
    for row in platformRows:
        if row.len >= 2:
            byPlatform.add((platform: row[0], count: parseInt(row[1])))
    
    result = (
        total: total,
        completed: completed,
        failed: failed,
        pending: pending,
        totalSize: totalSize,
        byPlatform: byPlatform
    )

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

proc detectPlatform*(url: string): DownloadPlatform =
    ## Detect platform from URL
    let lowerUrl = url.toLowerAscii()
    
    if "youtube.com" in lowerUrl or "youtu.be" in lowerUrl:
        result = dpYouTube
    elif "tiktok.com" in lowerUrl:
        result = dpTikTok
    elif "instagram.com" in lowerUrl:
        result = dpInstagram
    elif "twitter.com" in lowerUrl or "x.com" in lowerUrl:
        result = dpTwitter
    elif "facebook.com" in lowerUrl or "fb.watch" in lowerUrl:
        result = dpFacebook
    elif "linkedin.com" in lowerUrl:
        result = dpLinkedIn
    elif "bsky.app" in lowerUrl or "bluesky" in lowerUrl:
        result = dpBlueSky
    elif "reddit.com" in lowerUrl or "redd.it" in lowerUrl:
        result = dpReddit
    else:
        result = dpGeneric

proc formatFileSize*(size: int64): string =
    ## Format file size in human readable format
    if size < 1024:
        result = $size & " B"
    elif size < 1024 * 1024:
        result = fmt"{size.float / 1024.0:.1f} KB"
    elif size < 1024 * 1024 * 1024:
        result = fmt"{size.float / (1024.0 * 1024.0):.1f} MB"
    else:
        result = fmt"{size.float / (1024.0 * 1024.0 * 1024.0):.2f} GB"

proc formatDuration*(seconds: int): string =
    ## Format duration in HH:MM:SS or MM:SS format
    let hours = seconds div 3600
    let mins = (seconds mod 3600) div 60
    let secs = seconds mod 60
    
    if hours > 0:
        result = fmt"{hours:02d}:{mins:02d}:{secs:02d}"
    else:
        result = fmt"{mins:02d}:{secs:02d}"

proc addTags*(db: Db, id: int, newTags: seq[string]): bool =
    ## Add tags to a download
    let downloadOpt = db.getDownload(id)
    if downloadOpt.isSome:
        var download = downloadOpt.get()
        var existingTags = download.tags.split(",").mapIt(it.strip()).filterIt(it.len > 0)
        
        for tag in newTags:
            let trimmed = tag.strip()
            if trimmed.len > 0 and trimmed notin existingTags:
                existingTags.add(trimmed)
        
        download.tags = existingTags.join(",")
        db.updateDownload(download)
        return true
    return false

proc setNotes*(db: Db, id: int, notes: string): bool =
    ## Set notes for a download
    let downloadOpt = db.getDownload(id)
    if downloadOpt.isSome:
        var download = downloadOpt.get()
        download.notes = some(notes)
        db.updateDownload(download)
        return true
    return false
