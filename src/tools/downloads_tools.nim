## downloads_tools.nim - Download tracking tools for GLD Agent
##
## Tools for recording, querying, and managing tracked downloads.

import
    std/[
        json
        ,asyncdispatch
        ,strformat
        ,options
        ,os
        ,strutils
        ,sequtils
    ]

import
    llmm
    ,llmm/tools

import
    ../gld/src/downloads_db as dl_db

# -----------------------------------------------------------------------------
# Helper: Convert Download to JSON for tool responses
# -----------------------------------------------------------------------------

proc downloadToJson(dl: Download): JsonNode =
    ## Convert a Download to JSON representation
    result = %*{
        "id": dl.id,
        "source_url": dl.sourceUrl,
        "platform": $dl.platform,
        "filename": dl.filename,
        "download_path": dl.downloadPath,
        "content_type": $dl.contentType,
        "status": $dl.status,
        "tags": dl.tags.split(",").filterIt(it.len > 0),
        "created_at": dl.createdAt,
        "updated_at": dl.updatedAt
    }
    
    if dl.originalFilename.isSome:
        result["original_filename"] = %dl.originalFilename.get()
    if dl.fileSize.isSome:
        result["file_size"] = %dl.fileSize.get()
        result["file_size_human"] = %dl_db.formatFileSize(dl.fileSize.get())
    if dl.mimeType.isSome:
        result["mime_type"] = %dl.mimeType.get()
    if dl.fileExtension.isSome:
        result["file_extension"] = %dl.fileExtension.get()
    if dl.title.isSome:
        result["title"] = %dl.title.get()
    if dl.description.isSome:
        result["description"] = %dl.description.get()
    if dl.duration.isSome:
        result["duration_seconds"] = %dl.duration.get()
        result["duration_formatted"] = %dl_db.formatDuration(dl.duration.get())
    if dl.thumbnailUrl.isSome:
        result["thumbnail_url"] = %dl.thumbnailUrl.get()
    if dl.startedAt.isSome:
        result["started_at"] = %dl.startedAt.get()
    if dl.completedAt.isSome:
        result["completed_at"] = %dl.completedAt.get()
    if dl.errorMessage.isSome:
        result["error_message"] = %dl.errorMessage.get()
    if dl.httpStatusCode.isSome:
        result["http_status_code"] = %dl.httpStatusCode.get()
    if dl.metadataJson.isSome:
        result["metadata"] = parseJson(dl.metadataJson.get())
    if dl.notes.isSome:
        result["notes"] = %dl.notes.get()

proc downloadsToJson(downloads: seq[Download]): JsonNode =
    ## Convert a sequence of Downloads to JSON
    result = newJArray()
    for dl in downloads:
        result.add downloadToJson(dl)

# -----------------------------------------------------------------------------
# Tool: Record Download
# -----------------------------------------------------------------------------

proc recordDownloadHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let sourceUrl = args["source_url"].getStr()
    let filename = args["filename"].getStr()
    let downloadPath = args["download_path"].getStr()
    
    # Optional fields
    var platform = dl_db.detectPlatform(sourceUrl)
    if args.hasKey("platform"):
        try:
            platform = parseEnum[DownloadPlatform](args["platform"].getStr())
        except:
            discard
    
    var contentType = dctUnknown
    if args.hasKey("content_type"):
        try:
            contentType = parseEnum[DownloadContentType](args["content_type"].getStr())
        except:
            # Try to detect from filename extension
            let ext = filename.splitFile().ext.toLowerAscii()
            case ext
            of ".mp4", ".mov", ".avi", ".mkv", ".webm": contentType = dctVideo
            of ".mp3", ".wav", ".aac", ".ogg", ".flac": contentType = dctAudio
            of ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp": contentType = dctImage
            of ".pdf", ".doc", ".docx", ".txt", ".zip": contentType = dctDocument
            else: discard
    
    var originalFilename = none(string)
    if args.hasKey("original_filename"):
        originalFilename = some(args["original_filename"].getStr())
    
    var fileSize = none(int64)
    if args.hasKey("file_size"):
        fileSize = some(args["file_size"].getBiggestInt())
    
    var mimeType = none(string)
    if args.hasKey("mime_type"):
        mimeType = some(args["mime_type"].getStr())
    
    var title = none(string)
    if args.hasKey("title"):
        title = some(args["title"].getStr())
    
    var description = none(string)
    if args.hasKey("description"):
        description = some(args["description"].getStr())
    
    var duration = none(int)
    if args.hasKey("duration"):
        duration = some(args["duration"].getInt())
    
    var thumbnailUrl = none(string)
    if args.hasKey("thumbnail_url"):
        thumbnailUrl = some(args["thumbnail_url"].getStr())
    
    var metadataJson = none(string)
    if args.hasKey("metadata"):
        metadataJson = some($args["metadata"])
    
    var tags: seq[string] = @[]
    if args.hasKey("tags"):
        if args["tags"].kind == JArray:
            for tag in args["tags"]:
                tags.add(tag.getStr())
        else:
            tags = args["tags"].getStr().split(",").mapIt(it.strip())
    
    var notes = none(string)
    if args.hasKey("notes"):
        notes = some(args["notes"].getStr())
    
    let db = openDownloadsDb()
    let download = dl_db.recordDownload(
        db = db
        ,sourceUrl = sourceUrl
        ,filename = filename
        ,downloadPath = downloadPath
        ,platform = platform
        ,contentType = contentType
        ,originalFilename = originalFilename
        ,fileSize = fileSize
        ,mimeType = mimeType
        ,title = title
        ,description = description
        ,duration = duration
        ,thumbnailUrl = thumbnailUrl
        ,metadataJson = metadataJson
        ,tags = tags
        ,notes = notes
    )
    
    return %*{
        "success": true
        ,"message": &"Recorded download #{download.id}"
        ,"download": downloadToJson(download)
    }

proc newRecordDownloadTool*(): Tool =
    ## Create a tool for recording a new download
    Tool(
        name: "record_download"
        ,description: "Record a new download in the database. Use this whenever a file is downloaded."
        ,parameters: %*{
            "type": "object"
            ,"required": @["source_url", "filename", "download_path"]
            ,"properties": %*{
                "source_url": %*{
                    "type": "string"
                    ,"description": "The original URL the file was downloaded from"
                }
                ,"filename": %*{
                    "type": "string"
                    ,"description": "The local filename"
                }
                ,"download_path": %*{
                    "type": "string"
                    ,"description": "Full local path where the file was saved"
                }
                ,"platform": %*{
                    "type": "string"
                    ,"enum": @["youtube", "tiktok", "instagram", "twitter", "facebook", "linkedin", "bluesky", "reddit", "generic"]
                    ,"description": "Platform the download came from (auto-detected if not specified)"
                }
                ,"content_type": %*{
                    "type": "string"
                    ,"enum": @["video", "audio", "image", "document", "unknown"]
                    ,"description": "Type of content downloaded"
                }
                ,"original_filename": %*{
                    "type": "string"
                    ,"description": "Original filename from the source"
                }
                ,"file_size": %*{
                    "type": "integer"
                    ,"description": "File size in bytes"
                }
                ,"mime_type": %*{
                    "type": "string"
                    ,"description": "MIME type of the file"
                }
                ,"title": %*{
                    "type": "string"
                    ,"description": "Title of the content if available"
                }
                ,"description": %*{
                    "type": "string"
                    ,"description": "Description of the content"
                }
                ,"duration": %*{
                    "type": "integer"
                    ,"description": "Duration in seconds (for media files)"
                }
                ,"thumbnail_url": %*{
                    "type": "string"
                    ,"description": "URL of thumbnail/preview image"
                }
                ,"metadata": %*{
                    "type": "object"
                    ,"description": "Additional metadata as JSON object"
                }
                ,"tags": %*{
                    "type": "array"
                    ,"items": %*{"type": "string"}
                    ,"description": "Tags for organizing the download"
                }
                ,"notes": %*{
                    "type": "string"
                    ,"description": "User notes about this download"
                }
            }
        }
        ,handler: recordDownloadHandler
    )

# -----------------------------------------------------------------------------
# Tool: List Downloads
# -----------------------------------------------------------------------------

proc listDownloadsHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let db = openDownloadsDb()
    
    var status = none(DownloadStatus)
    if args.hasKey("status"):
        try:
            status = some(parseEnum[DownloadStatus](args["status"].getStr()))
        except:
            discard
    
    var platform = none(DownloadPlatform)
    if args.hasKey("platform"):
        try:
            platform = some(parseEnum[DownloadPlatform](args["platform"].getStr()))
        except:
            discard
    
    var contentType = none(DownloadContentType)
    if args.hasKey("content_type"):
        try:
            contentType = some(parseEnum[DownloadContentType](args["content_type"].getStr()))
        except:
            discard
    
    var tag = none(string)
    if args.hasKey("tag"):
        tag = some(args["tag"].getStr())
    
    var limit = 50
    if args.hasKey("limit"):
        limit = args["limit"].getInt()
    
    var offset = 0
    if args.hasKey("offset"):
        offset = args["offset"].getInt()
    
    let downloads = dl_db.listDownloads(db, status, platform, contentType, tag, limit, offset)
    
    return %*{
        "success": true
        ,"count": downloads.len
        ,"limit": limit
        ,"offset": offset
        ,"downloads": downloadsToJson(downloads)
    }

proc newListDownloadsTool*(): Tool =
    ## Create a tool for listing tracked downloads
    Tool(
        name: "list_tracked_downloads"
        ,description: "List tracked downloads with optional filters. Use this to see what's been downloaded."
        ,parameters: %*{
            "type": "object"
            ,"properties": %*{
                "status": %*{
                    "type": "string"
                    ,"enum": @["pending", "downloading", "completed", "failed", "cancelled"]
                    ,"description": "Filter by download status"
                }
                ,"platform": %*{
                    "type": "string"
                    ,"enum": @["youtube", "tiktok", "instagram", "twitter", "facebook", "linkedin", "bluesky", "reddit", "generic"]
                    ,"description": "Filter by platform"
                }
                ,"content_type": %*{
                    "type": "string"
                    ,"enum": @["video", "audio", "image", "document", "unknown"]
                    ,"description": "Filter by content type"
                }
                ,"tag": %*{
                    "type": "string"
                    ,"description": "Filter by tag"
                }
                ,"limit": %*{
                    "type": "integer"
                    ,"default": 50
                    ,"description": "Maximum number of results"
                }
                ,"offset": %*{
                    "type": "integer"
                    ,"default": 0
                    ,"description": "Offset for pagination"
                }
            }
        }
        ,handler: listDownloadsHandler
    )

# -----------------------------------------------------------------------------
# Tool: Search Downloads
# -----------------------------------------------------------------------------

proc searchDownloadsHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let searchTerm = args["query"].getStr()
    if searchTerm.len == 0:
        return %*{"error": "Query is required"}
    
    var limit = 50
    if args.hasKey("limit"):
        limit = args["limit"].getInt()
    
    let db = openDownloadsDb()
    let downloads = dl_db.searchDownloads(db, searchTerm, limit)
    
    return %*{
        "success": true
        ,"query": searchTerm
        ,"count": downloads.len
        ,"downloads": downloadsToJson(downloads)
    }

proc newSearchDownloadsTool*(): Tool =
    ## Create a tool for searching downloads
    Tool(
        name: "search_downloads"
        ,description: "Search downloads by title, filename, URL, description, notes, or tags."
        ,parameters: %*{
            "type": "object"
            ,"required": @["query"]
            ,"properties": %*{
                "query": %*{
                    "type": "string"
                    ,"description": "Search term"
                }
                ,"limit": %*{
                    "type": "integer"
                    ,"default": 50
                    ,"description": "Maximum number of results"
                }
            }
        }
        ,handler: searchDownloadsHandler
    )

# -----------------------------------------------------------------------------
# Tool: Update Download Status
# -----------------------------------------------------------------------------

proc updateDownloadStatusHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    let status = parseEnum[DownloadStatus](args["status"].getStr())
    
    var errorMessage = none(string)
    if args.hasKey("error_message"):
        errorMessage = some(args["error_message"].getStr())
    
    var httpStatusCode = none(int)
    if args.hasKey("http_status_code"):
        httpStatusCode = some(args["http_status_code"].getInt())
    
    let db = openDownloadsDb()
    let success = dl_db.updateDownloadStatus(db, id, status, errorMessage, httpStatusCode)
    
    if success:
        return %*{
            "success": true
            ,"message": &"Download #{id} status updated to {$status}"
            ,"id": id
            ,"status": $status
        }
    else:
        return %*{ "success": false, "error": "Download not found or no changes made" }

proc newUpdateDownloadStatusTool*(): Tool =
    ## Create a tool for updating download status
    Tool(
        name: "update_download_status"
        ,description: "Update the status of a download (e.g., mark as completed or failed)."
        ,parameters: %*{
            "type": "object"
            ,"required": @["id", "status"]
            ,"properties": %*{
                "id": %*{
                    "type": "integer"
                    ,"description": "Download ID"
                }
                ,"status": %*{
                    "type": "string"
                    ,"enum": @["pending", "downloading", "completed", "failed", "cancelled"]
                    ,"description": "New status"
                }
                ,"error_message": %*{
                    "type": "string"
                    ,"description": "Error message if status is failed"
                }
                ,"http_status_code": %*{
                    "type": "integer"
                    ,"description": "HTTP status code if applicable"
                }
            }
        }
        ,handler: updateDownloadStatusHandler
    )

# -----------------------------------------------------------------------------
# Tool: Get Download Stats
# -----------------------------------------------------------------------------

proc getDownloadStatsHandler(args: JsonNode): Future[JsonNode] {.async.} =
    let db = openDownloadsDb()
    let stats = dl_db.getStats(db)
    
    var platformBreakdown = newJArray()
    for item in stats.byPlatform:
        let platformObj = %*{
            "platform": item.platform,
            "count": item.count
        }
        platformBreakdown.add(platformObj)
    
    return %*{
        "success": true
        ,"stats": {
            "total": stats.total
            ,"completed": stats.completed
            ,"failed": stats.failed
            ,"pending": stats.pending
            ,"total_size_bytes": stats.totalSize
            ,"total_size_formatted": dl_db.formatFileSize(stats.totalSize)
            ,"by_platform": platformBreakdown
        }
    }

proc newGetDownloadStatsTool*(): Tool =
    ## Create a tool for getting download statistics
    Tool(
        name: "get_download_stats"
        ,description: "Get statistics about all tracked downloads."
        ,parameters: %*{ "type": "object", "properties": %*{} }
        ,handler: getDownloadStatsHandler
    )

# -----------------------------------------------------------------------------
# Tool: Add Tags to Download
# -----------------------------------------------------------------------------

proc addDownloadTagsHandler(args: JsonNode): Future[JsonNode] {.async.} =
    if not args.hasKey("id"):
        return %*{"error": "ID is required"}
    
    let id = args["id"].getInt()
    var tags: seq[string] = @[]
    
    if args["tags"].kind == JArray:
        for tag in args["tags"]:
            tags.add(tag.getStr())
    else:
        tags = args["tags"].getStr().split(",").mapIt(it.strip())
    
    let db = openDownloadsDb()
    let success = dl_db.addTags(db, id, tags)
    
    if success:
        return %*{
            "success": true
            ,"message": &"Tags added to download #{id}"
            ,"id": id
            ,"tags": tags
        }
    else:
        return %*{ "success": false, "error": "Download not found" }

proc newAddDownloadTagsTool*(): Tool =
    ## Create a tool for adding tags to a download
    Tool(
        name: "add_download_tags"
        ,description: "Add tags to a download for organization."
        ,parameters: %*{
            "type": "object"
            ,"required": @["id", "tags"]
            ,"properties": %*{
                "id": %*{
                    "type": "integer"
                    ,"description": "Download ID"
                }
                ,"tags": %*{
                    "type": "array"
                    ,"items": %*{"type": "string"}
                    ,"description": "Tags to add"
                }
            }
        }
        ,handler: addDownloadTagsHandler
    )

# -----------------------------------------------------------------------------
# Toolkit
# -----------------------------------------------------------------------------

proc DownloadsToolkit*(): Toolkit =
    ## Create a toolkit with all download tracking tools
    result = newToolkit("downloads", "Download tracking and management tools")
    result.add newRecordDownloadTool()
    result.add newListDownloadsTool()
    result.add newSearchDownloadsTool()
    result.add newUpdateDownloadStatusTool()
    result.add newGetDownloadStatsTool()
    result.add newAddDownloadTagsTool()
