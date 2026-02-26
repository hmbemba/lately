## lately_tools.nim - Main toolkit registry for GLD Agent
##
## Combines all Lately toolkits into a single import.

import
    llmm
    ,llmm/tools

import
    agent_config
    ,account_tools
    ,download_tools
    ,post_tools
    ,queue_tools
    ,analyze_tools
    ,ideas_tools
    ,downloads_tools

export
    agent_config
    ,account_tools
    ,download_tools
    ,post_tools
    ,queue_tools
    ,analyze_tools
    ,ideas_tools
    ,downloads_tools

# -----------------------------------------------------------------------------
# Lately Toolkit
# -----------------------------------------------------------------------------

proc LatelyToolkit*(): Toolkit =
    ## Complete toolkit for GLD Agent with all social media management tools
    result = newToolkit("lately", "Social media management tools for Late.dev platform")
    
    # Add account tools
    result.add ListAccountsTool()
    result.add AccountHealthTool()
    
    # Add download tools
    result.add DownloadMediaTool()
    result.add ListDownloadsTool()
    
    # Add post tools
    result.add CreatePostTool()
    result.add CreateThreadTool()
    
    # Add queue tools
    result.add ViewQueueTool()
    result.add NextQueueSlotTool()
    
    # Add analyze tools
    result.add AnalyzeArticleTool()
    result.add AnalyzeTweetTool()
    result.add SuggestClipsTool()
    
    # Add ideas tools
    let ideasTools = IdeasToolkit()
    for tool in ideasTools:
        result.add tool
    
    # Add downloads tracking tools
    let downloadsTools = DownloadsToolkit()
    for tool in downloadsTools:
        result.add tool

proc LatelyReadOnlyToolkit*(): Toolkit =
    ## Read-only toolkit (safer - no posting or downloading)
    result = newToolkit("lately_readonly", "Read-only social media management tools")
    
    # Add account tools
    result.add ListAccountsTool()
    result.add AccountHealthTool()
    
    # Add queue tools
    result.add ViewQueueTool()
    result.add NextQueueSlotTool()
    
    # Add analyze tools
    result.add AnalyzeArticleTool()
    result.add AnalyzeTweetTool()
    result.add SuggestClipsTool()
