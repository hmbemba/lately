## agent_config.nim - Agent configuration for GLD CLI
##
## Manages agent configuration including:
## - API keys for LLM providers
## - Model selection
## - System prompts
## - Policy settings (max_tool_calls, etc.)
##
## Agent is OFF by default. Users must run `gld init` or `gld agent --init` to configure.

import
    std/[
        os
        ,strutils
        ,options
        ,json
        ,strformat
    ]

import
    ic
    ,jsony
    ,rz

import
    ../gld/src/paths

# -----------------------------------------------------------------------------
# Constants - Sane defaults
# -----------------------------------------------------------------------------

const
    DEFAULT_MAX_TOOL_CALLS* = 100
    DEFAULT_TIMEOUT_MINUTES* = 10
    DEFAULT_MODEL* = "gpt-4o-mini"

    DEFAULT_SYSTEM_PROMPT* = """You are GLD Agent, an AI assistant for the Late.dev social media management platform.

Your job is to help users manage their social media presence across platforms like X (Twitter), Threads, Instagram, LinkedIn, TikTok, YouTube, Facebook, Bluesky, and more.

You have access to tools that can:
- Download media from social platforms
- Create and schedule posts
- Analyze content and suggest clips or posts
- Manage connected accounts
- Check queue status and upcoming posts

When helping users:
1. Ask clarifying questions when needed
2. Confirm destructive actions (posting, downloading, scheduling) before executing
3. Show your work - explain what tools you're using and why
4. Handle errors gracefully and suggest alternatives

Always respect user privacy and never share API keys or sensitive account information."""

    DEFAULT_KIMI_MODEL* = "kimi-k2"

# -----------------------------------------------------------------------------
# Types
# -----------------------------------------------------------------------------

type
    LlmProviderKind* = enum
        lpOpenAI
        lpKimi

    PromptCacheRetention* = enum
        pcrInMemory
        pcr24Hour

    AgentPolicyConfig* = object
        maxToolCalls*   : int
        timeoutMinutes* : int


    AgentConfig* = object
        enabled*            : bool
        provider*           : LlmProviderKind
        apiKey*             : string
        model*              : string
        systemPrompt*       : string
        policy*             : AgentPolicyConfig
        workspaceDir*       : string  ## For agent SQLite DB
        showToolCalls*      : bool    ## Show tool calls in REPL (default: true)
        confirmDestructive* : bool    ## Confirm before destructive actions (default: true)
        promptCacheKey*     : string  ## Key for prompt caching
        promptCacheRetention*: PromptCacheRetention  ## Cache retention policy
        personaContent*     : string  ## Static persona for prompt caching
        staticContext*      : string  ## Additional static context


# -----------------------------------------------------------------------------
# Default Configuration
# -----------------------------------------------------------------------------

proc defaultAgentConfig*(): AgentConfig =
    result = AgentConfig(
        enabled             : false
        ,provider           : lpOpenAI
        ,apiKey             : ""
        ,model              : DEFAULT_MODEL
        ,systemPrompt       : DEFAULT_SYSTEM_PROMPT
        ,policy             : AgentPolicyConfig(
            maxToolCalls    : DEFAULT_MAX_TOOL_CALLS
            ,timeoutMinutes : DEFAULT_TIMEOUT_MINUTES
        )
        ,workspaceDir       : ""  # Will default to .gld/agent
        ,showToolCalls      : true
        ,confirmDestructive : true
        ,promptCacheKey     : ""
        ,promptCacheRetention: pcrInMemory
        ,personaContent     : ""
        ,staticContext      : ""
    )

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

proc agentConfigPath*(): string =
    let gldDir = gldDir()
    return gldDir / "agent_config.json"

proc agentDbPath*(): string =
    let gldDir = gldDir()
    return gldDir / "agent.db"

# -----------------------------------------------------------------------------
# Load/Save
# -----------------------------------------------------------------------------

proc loadAgentConfig*(): AgentConfig =
    let p = agentConfigPath()
    if not fileExists(p):
        result = defaultAgentConfig()
        return

    let raw = readFile(p)
    if raw.strip.len == 0:
        result = defaultAgentConfig()
        return

    try:
        result = raw.fromJson(AgentConfig)
    except CatchableError as e:
        icr "Failed to parse agent config. Using defaults.", e.msg
        result = defaultAgentConfig()

proc saveAgentConfig*(conf: AgentConfig) =
    let
        p   = agentConfigPath()
        raw = conf.toJson()
    writeFile(p, raw)

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

proc isAgentConfigured*(conf: AgentConfig): bool =
    ## Check if agent is properly configured and enabled
    if not conf.enabled:
        return false
    if conf.apiKey.strip.len == 0:
        return false
    return true

proc requireAgentConfig*(): AgentConfig =
    ## Load and validate agent config, raise error if not configured
    let conf = loadAgentConfig()
    if not conf.enabled:
        raise newException(ValueError, "Agent is not enabled. Run: gld agent --init or gld init")
    if conf.apiKey.strip.len == 0:
        raise newException(ValueError, "Agent API key not configured. Run: gld agent --init")
    return conf

# -----------------------------------------------------------------------------
# Provider Helpers
# -----------------------------------------------------------------------------

proc providerName*(p: LlmProviderKind): string =
    case p
    of lpOpenAI: "OpenAI"
    of lpKimi: "Kimi"

proc providerFromString*(s: string): LlmProviderKind =
    let lower = s.toLowerAscii
    case lower
    of "openai", "oai": lpOpenAI
    of "kimi", "moonshot": lpKimi
    else: lpOpenAI

# -----------------------------------------------------------------------------
# GC-Safe Confirmation Helper
# -----------------------------------------------------------------------------

proc confirmDestructiveAction*(action: string): bool {.gcsafe.} =
    ## GC-safe confirmation for destructive actions.
    ## Returns true if user confirms, false otherwise.
    ## Uses stdin directly to avoid termui's gcsafe issues.
    try:
        stdout.write("\nÃ¢Å¡Â Ã¯Â¸í²  Confirm: ")
        stdout.write(action)
        stdout.write(" [y/N]: ")
        stdout.flushFile()
        
        var response: string
        if stdin.readLine(response):
            let trimmed = response.strip().toLowerAscii
            return trimmed == "y" or trimmed == "yes"
        return false
    except CatchableError:
        # If we can't read stdin, default to not confirming (safety)
        return false

proc confirmPostCreation*(platforms: seq[string]; isDraft: bool; scheduleFor: Option[string]): bool {.gcsafe.} =
    ## Specialized confirmation for post creation
    let action = 
        if isDraft: "save this draft"
        elif scheduleFor.isSome: "schedule this post"
        else: "publish to " & platforms.join(", ")
    return confirmDestructiveAction(action)

proc confirmDownload*(url: string): bool {.gcsafe.} =
    ## Specialized confirmation for downloads
    return confirmDestructiveAction("download from " & url)

# -----------------------------------------------------------------------------
# Display
# -----------------------------------------------------------------------------

proc cacheRetentionToString*(retention: PromptCacheRetention): string =
    case retention
    of pcrInMemory: "in_memory (5-10 min)"
    of pcr24Hour: "24h (extended)"

proc `$`*(conf: AgentConfig): string =
    var parts: seq[string]
    parts.add &"Enabled: {conf.enabled}"
    parts.add &"Provider: {conf.provider.providerName}"
    parts.add &"Model: {conf.model}"
    parts.add &"API Key: {'*'.repeat(min(8, conf.apiKey.len))}..."
    parts.add &"Max Tool Calls: {conf.policy.maxToolCalls}"
    parts.add &"Timeout: {conf.policy.timeoutMinutes} min"
    parts.add &"Workspace: {conf.workspaceDir}"
    parts.add &"Show Tool Calls: {conf.showToolCalls}"
    parts.add &"Confirm Destructive: {conf.confirmDestructive}"
    parts.add &"Prompt Cache Key: {conf.promptCacheKey}"
    parts.add &"Cache Retention: {cacheRetentionToString(conf.promptCacheRetention)}"
    if conf.personaContent.len > 0:
        parts.add &"Persona: {conf.personaContent[0..<min(50, conf.personaContent.len)]}..."
    if conf.staticContext.len > 0:
        parts.add &"Static Context: {conf.staticContext[0..<min(50, conf.staticContext.len)]}..."
    result = parts.join("\n")
