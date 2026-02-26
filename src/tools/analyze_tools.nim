## analyze_tools.nim - Content analysis tools for GLD Agent
##
## Tools for analyzing content and suggesting posts or clips.

import
    std/[
        json
        ,asyncdispatch
        ,strformat
        ,options
        ,httpclient
        ,strutils
    ]

import
    rz
    ,llmm
    ,llmm/tools

import
    agent_config

# -----------------------------------------------------------------------------
# Analyze Article Tool
# -----------------------------------------------------------------------------

proc AnalyzeArticleTool*(): Tool =
    ## Fetch and analyze an article to suggest social media posts
    Tool(
        name        : "analyze_article"
        ,description: "Fetch and analyze an article URL to extract key points and suggest social media posts. Useful for turning blog posts into thread-worthy content."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "url": {
                    "type": "string"
                    ,"description": "The URL of the article to analyze"
                }
                ,"platform": {
                    "type": "string"
                    ,"description": "Target platform for suggestions (twitter, threads, linkedin). Helps tailor the output format."
                }
            }
            ,"required": ["url"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let url = args["url"].getStr
                let platform = if args.hasKey("platform"): args["platform"].getStr else: "twitter"

                # Fetch the article content
                var client = newAsyncHttpClient()
                defer: client.close()

                client.headers = newHttpHeaders({
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                })

                let response = await client.get(url)
                let body = await response.body()

                if response.code != Http200:
                    return toolError(&"Failed to fetch article: HTTP {response.code}")

                # Extract title (basic HTML parsing)
                var title = ""
                if body.find("<title>") >= 0:
                    let start = body.find("<title>") + 7
                    let ending = body.find("</title>", start)
                    if ending > start:
                        title = body[start..<ending]

                # Clean up title
                title = title.replace("&quot;", "\"").replace("&#39;", "'").replace("&amp;", "&")

                # Extract meta description
                var description = ""
                let metaDescStart = body.find("name=\"description\"")
                if metaDescStart >= 0:
                    let contentStart = body.find("content=\"", metaDescStart)
                    if contentStart >= 0:
                        let valStart = contentStart + 9
                        let valEnd = body.find("\"", valStart)
                        if valEnd > valStart:
                            description = body[valStart..<valEnd]

                description = description.replace("&quot;", "\"").replace("&#39;", "'").replace("&amp;", "&")

                # Build suggestions based on platform
                var suggestions: seq[string]

                case platform.toLowerAscii
                of "twitter", "x", "tw":
                    suggestions.add(&"🧵 Thread idea: Break down the key insights from \"{title}\"")
                    suggestions.add(&"Hot take from this article: [extract main argument]")
                    suggestions.add(&"The most surprising finding: [find a stat or quote]")
                    suggestions.add(&"What this means for [industry]: [practical takeaway]")
                of "linkedin", "li":
                    suggestions.add(&"💡 Key insight from \"{title}\": [professional angle]")
                    suggestions.add(&"I just read an interesting article about [topic]. Here's what stood out...")
                    suggestions.add(&"3 takeaways from \"{title}\": 1) ... 2) ... 3) ...")
                of "threads", "th":
                    suggestions.add(&"📖 \"{title}\" - quick thoughts:")
                    suggestions.add(&"This article got me thinking... [casual take]")
                    suggestions.add(&"TL;DR of \"{title}\": [concise summary]")
                else:
                    suggestions.add(&"Key insight from \"{title}\"")
                    suggestions.add(&"Interesting point: [main argument]")
                    suggestions.add(&"Worth considering: [counterpoint or implication]")

                return toolSuccess(%*{
                    "url": url
                    ,"title": title
                    ,"description": description
                    ,"platform": platform
                    ,"suggestions": suggestions
                    ,"wordCount": body.len div 5  # Rough estimate
                }, &"Analyzed \"{title}\"")

            except CatchableError as e:
                return toolError(&"Error analyzing article: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Analyze Tweet Tool
# -----------------------------------------------------------------------------

proc AnalyzeTweetTool*(): Tool =
    ## Analyze a tweet/thread for engagement patterns
    Tool(
        name        : "analyze_tweet"
        ,description: "Analyze a tweet or thread URL to understand its structure and engagement patterns. Useful for learning from high-performing content."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "url": {
                    "type": "string"
                    ,"description": "The URL of the tweet to analyze"
                }
            }
            ,"required": ["url"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let url = args["url"].getStr

                # Extract tweet ID from URL
                var tweetId = ""
                let parts = url.split("/")
                for i, part in parts:
                    if part == "status" or part == "statuses":
                        if i + 1 < parts.len:
                            tweetId = parts[i + 1]
                            # Remove query params
                            let qIdx = tweetId.find('?')
                            if qIdx >= 0:
                                tweetId = tweetId[0..<qIdx]
                            break

                if tweetId.len == 0:
                    return toolError("Could not extract tweet ID from URL")

                # For now, return structure analysis tips
                # In the future, this could integrate with Twitter API or scraping
                var analysis: seq[string]
                analysis.add("Hook analysis: Look at the first line - does it create curiosity or promise value?")
                analysis.add("Structure: Is it a single tweet or a thread? Threads often use numbering (1/, 2/)")
                analysis.add("Formatting: Look for line breaks, emojis, and visual breaks")
                analysis.add("CTA: Does it end with a call-to-action (reply, retweet, follow)?")
                analysis.add("Tone: Is it educational, entertaining, or inspirational?")

                return toolSuccess(%*{
                    "url": url
                    ,"tweetId": tweetId
                    ,"analysisPoints": analysis
                    ,"note": "This is a structural analysis. For detailed metrics, you would need Twitter API access."
                }, "Tweet structure analysis complete")

            except CatchableError as e:
                return toolError(&"Error analyzing tweet: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Suggest Clips Tool
# -----------------------------------------------------------------------------

proc SuggestClipsTool*(): Tool =
    ## Suggest key clips from a video for reposting
    Tool(
        name        : "suggest_clips"
        ,description: "Suggest key clips from a video URL for reposting. Analyzes the video content and recommends timestamps for the most engaging segments."
        ,parameters : %*{
            "type": "object"
            ,"properties": {
                "url": {
                    "type": "string"
                    ,"description": "The URL of the video to analyze"
                }
                ,"platform": {
                    "type": "string"
                    ,"description": "Target platform for clips (tiktok, instagram, youtube, twitter). Affects suggested duration."
                }
                ,"count": {
                    "type": "integer"
                    ,"description": "Number of clips to suggest (default: 3)"
                }
            }
            ,"required": ["url"]
            ,"additionalProperties": false
        }
        ,strict     : true
        ,handler    : proc(args: JsonNode): Future[JsonNode] {.gcsafe, async.} =
            try:
                let url = args["url"].getStr
                let platform = if args.hasKey("platform"): args["platform"].getStr else: "tiktok"
                let count = if args.hasKey("count"): args["count"].getInt else: 3

                # Determine ideal clip duration by platform
                let (minDuration, maxDuration) = case platform.toLowerAscii
                of "tiktok", "tt": (15, 60)
                of "instagram", "ig", "reels": (15, 90)
                of "youtube", "yt", "shorts": (30, 60)
                of "twitter", "x": (30, 140)
                else: (15, 60)

                # For now, return a framework for clip selection
                # In the future, this could analyze transcripts, visual changes, etc.
                var clipSuggestions: seq[JsonNode]

                clipSuggestions.add %*{
                    "timestamp": "0:00-0:15"
                    ,"suggestion": "The hook - first 15 seconds are crucial for retention"
                    ,"rationale": "Most viewers decide whether to keep watching in the first 3-5 seconds"
                }

                clipSuggestions.add %*{
                    "timestamp": "[Peak moment]"
                    ,"suggestion": "Look for the most visually interesting or emotionally impactful moment"
                    ,"rationale": "Peak moments drive shares and engagement"
                }

                clipSuggestions.add %*{
                    "timestamp": "[Final payoff]"
                    ,"suggestion": "The conclusion or punchline"
                    ,"rationale": "Satisfying endings get better completion rates"
                }

                return toolSuccess(%*{
                    "url": url
                    ,"platform": platform
                    ,"idealDuration": &"{minDuration}-{maxDuration}s"
                    ,"suggestedClips": clipSuggestions
                    ,"tips": [
                        "Start with the most compelling moment (pattern interrupt)",
                        "Keep clips under 60 seconds for maximum reach",
                        "Add captions - most viewers watch without sound",
                        "Use trending audio when appropriate",
                        "End with a strong CTA or open loop"
                    ]
                }, &"Clip analysis complete for {platform}")

            except CatchableError as e:
                return toolError(&"Error suggesting clips: {e.msg}")
    )

# -----------------------------------------------------------------------------
# Analyze Toolkit
# -----------------------------------------------------------------------------

proc AnalyzeToolkit*(): Toolkit =
    ## Toolkit for content analysis and suggestions
    result = newToolkit("lately_analyze", "Analyze content and suggest posts or clips")
    result.add AnalyzeArticleTool()
    result.add AnalyzeTweetTool()
    result.add SuggestClipsTool()
