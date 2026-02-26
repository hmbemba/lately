## cmd_agent.nim - Agent command handler for GLD CLI
##
## Provides natural language interface to GLD via the llmm agent framework.
##
## Usage:
##   gld agent                         # Start interactive agent chat
##   gld agent "find clips from ..."   # Single-shot command
##   gld agent --init                  # Configure agent interactively
##   gld agent --status                # Show agent configuration status

import
    std/[
        strformat
        ,strutils
        ,options
        ,asyncdispatch
        ,os
        ,times
        ,tables
    ]

import
    termui
    ,llmm
    ,llmm/tools
    ,llmm/harness/primitives/sessions
    ,llmm/harness/providers/openai_responses
    ,llmm/harness/providers/kimi_chat
    ,llmm/harness/tools/hitltool
    ,llmm/harness/tools/timetools
    ,llmm/harness/tools/filesystem

import
    ../../tools/lately_tools
    ,store_config
    ,paths
    
# Import clients for provider creation
import llmm/providers/oai/oai_client
import llmm/providers/kimi/kimi_client

# -----------------------------------------------------------------------------
# API Key Validation
# -----------------------------------------------------------------------------

proc validateApiKey(conf: agent_config.AgentConfig): tuple[isValid: bool, message: string] =
    ## Validate API key format and basic requirements
    let key = conf.apiKey.strip()
    
    if key.len == 0:
        return (false, "API key is empty")
    
    case conf.provider
    of lpOpenAI:
        # OpenAI keys typically start with "sk-" 
        if not key.startsWith("sk-"):
            return (false, "OpenAI API key should start with 'sk-'")
        if key.len < 20:
            return (false, "OpenAI API key appears too short")
    of lpKimi:
        # Kimi/Moonshot keys also start with "sk-"
        if not key.startsWith("sk-"):
            return (false, "Kimi API key should start with 'sk-'")
        if key.len < 20:
            return (false, "Kimi API key appears too short")
    
    return (true, "")


# -----------------------------------------------------------------------------
# Cache Retention Helper
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

const
    AGENT_NAME = "GLD Agent"
    AGENT_ROLE = "Social Media Assistant"

# -----------------------------------------------------------------------------
# Command Line Parsing
# -----------------------------------------------------------------------------

proc hasFlag(args: seq[string], key: string): bool =
    for a in args:
        if a.toLowerAscii == key:
            return true
    return false

proc getPositionalMessage(args: seq[string]): Option[string] =
    ## Get everything that doesn't look like a flag
    var parts: seq[string]
    for a in args:
        if not a.startsWith("-"):
            parts.add a
    if parts.len > 0:
        return some(parts.join(" "))
    return none(string)

# -----------------------------------------------------------------------------
# Agent Initialization
# -----------------------------------------------------------------------------

proc initAgentInteractive*() =
    ## Interactive setup for agent configuration
    echo ""
    echo "√É¬∞√Ö¬∏√Ç¬§√¢‚Ç¨‚Äú GLD Agent Setup"
    echo "√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å"
    echo ""
    echo "The GLD Agent provides a natural language interface to your"
    echo "social media management via the Late.dev platform."
    echo ""

    var conf = loadAgentConfig()

    # Enable agent?
    echo "Would you like to enable the GLD Agent?"
    if not termuiConfirm("Enable agent?"):
        conf.enabled = false
        saveAgentConfig(conf)
        echo "\n√É¬¢√Ö‚Äú√¢‚Ç¨≈ì Agent disabled. You can re-run this setup anytime with:"
        echo "  gld agent --init"
        return

    conf.enabled = true

    # Provider selection
    echo ""
    echo "Select your LLM provider:"
    let providers = @["OpenAI (recommended)", "Kimi (Moonshot AI)"]
    let selected = termuiSelect("Provider:", providers)

    conf.provider = if selected.contains("OpenAI"): lpOpenAI else: lpKimi

    # API Key
    echo ""
    echo &"Enter your {conf.provider.providerName} API key:"
    echo "(Your key will be stored securely in ~/.gld/agent_config.json)"
    let apiKey = termuiAsk("API Key:")

    if apiKey.strip.len == 0:
        echo "\n√É¬¢√Ö¬°√Ç¬†√É¬Ø√Ç¬∏√≠¬≤Ì≤è  No API key provided. Agent will not be enabled."
        conf.enabled = false
        saveAgentConfig(conf)
        return

    conf.apiKey = apiKey.strip

    # Model selection
    echo ""
    if conf.provider == lpOpenAI:
        echo "Select OpenAI model:"
        let models = @[
            "GPT-5.2 Flagship ($1.75/$14.00 per 1M tokens, 400K context)",
            "GPT-5 Standard ($1.25/$10.00 per 1M tokens, 400K context)",
            "GPT-5 Mini ($0.25/$2.00 per 1M tokens, 400K context) [fast]",
            "GPT-5 Nano ($0.05/$0.40 per 1M tokens, 400K context) [cheapest]",
            "GPT-4.1 Long Context ($2.00/$8.00 per 1M tokens, 1M context)",
            "GPT-4o Multimodal ($2.50/$10.00 per 1M tokens, 128K context)",
            "o3 Reasoning ($2.00/$8.00 per 1M tokens, 200K context)",
            "o3-pro Expert ($20.00/$80.00 per 1M tokens, 200K context)",
            "Custom (enter manually)"
        ]
        let modelSel = termuiSelect("Model:", models)

        conf.model = if modelSel.contains("GPT-5.2"): "gpt-5.2"
                    elif modelSel.contains("GPT-5 Standard"): "gpt-5"
                    elif modelSel.contains("GPT-5 Mini"): "gpt-5-mini"
                    elif modelSel.contains("GPT-5 Nano"): "gpt-5-nano"
                    elif modelSel.contains("GPT-4.1"): "gpt-4.1"
                    elif modelSel.contains("GPT-4o"): "gpt-4o"
                    elif modelSel.contains("o3-pro"): "o3-pro"
                    elif modelSel.contains("o3 Reasoning"): "o3"
                    else: termuiAsk("Enter model name:")
    else:
        echo "Select Kimi model:"
        let models = @[
            "kimi-k2.5 ($0.60/$3.00 per 1M tokens, 256K context) [recommended - multimodal]",
            "kimi-k2.5-thinking ($0.60/$3.00 per 1M tokens, 256K context) [coding/math]",
            "kimi-k2-thinking ($0.60/$2.50 per 1M tokens, 256K context) [deep reasoning]",
            "kimi-k2-0905 ($0.60/$2.50 per 1M tokens, 256K context) [standard]",
            "kimi-latest ($2.00/$5.00 per 1M tokens, 128K context) [legacy stable]",
            "Custom (enter manually)"
        ]
        let modelSel = termuiSelect("Model:", models)

        conf.model = if modelSel.contains("kimi-k2.5-thinking"): "kimi-k2.5-thinking"
                    elif modelSel.contains("kimi-k2.5"): "kimi-k2.5"
                    elif modelSel.contains("kimi-k2-thinking"): "kimi-k2-thinking"
                    elif modelSel.contains("kimi-k2-0905"): "kimi-k2-0905"
                    elif modelSel.contains("kimi-latest"): "kimi-latest"
                    else: termuiAsk("Enter model name:")

    # Policy settings (with defaults)
    echo ""
    echo "Agent policy settings (press Enter for defaults):"

    let maxCallsStr = termuiAsk(&"Max tool calls per request [{DEFAULT_MAX_TOOL_CALLS}]:")
    if maxCallsStr.strip.len > 0:
        try:
            conf.policy.maxToolCalls = parseInt(maxCallsStr.strip)
        except:
            conf.policy.maxToolCalls = DEFAULT_MAX_TOOL_CALLS
    else:
        conf.policy.maxToolCalls = DEFAULT_MAX_TOOL_CALLS

    let timeoutStr = termuiAsk(&"Timeout in minutes [{DEFAULT_TIMEOUT_MINUTES}]:")
    if timeoutStr.strip.len > 0:
        try:
            conf.policy.timeoutMinutes = parseInt(timeoutStr.strip)
        except:
            conf.policy.timeoutMinutes = DEFAULT_TIMEOUT_MINUTES
    else:
        conf.policy.timeoutMinutes = DEFAULT_TIMEOUT_MINUTES

    # Workspace directory
    let gldDir = gldDir()
    conf.workspaceDir = gldDir / "agent"
    if not dirExists(conf.workspaceDir):
        createDir(conf.workspaceDir)

    # Save configuration
    saveAgentConfig(conf)

    echo ""
    echo "√É¬¢√Ö‚Äú√¢‚Ç¨¬¶ Agent configured successfully!"
    echo ""
    echo "You can now use:"
    echo "  gld agent                     # Interactive chat"
    echo "  gld agent \"your command\"     # Single-shot command"
    echo "  gld agent --status            # View configuration"
    echo ""

# -----------------------------------------------------------------------------
# Agent Status
# -----------------------------------------------------------------------------

proc showAgentStatus*() =
    ## Display current agent configuration status
    let conf = loadAgentConfig()

    echo ""
    echo "√É¬∞√Ö¬∏√Ç¬§√¢‚Ç¨‚Äú GLD Agent Status"
    echo "√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å√É¬¢√¢‚Ç¨Ì≤ù√≠¬≤Ì≤Å"
    echo ""

    if not conf.enabled:
        echo "Status: √É¬¢√≠¬≤Ì≤ù√Ö‚Äô Disabled"
        echo ""
        echo "To enable the agent, run:"
        echo "  gld agent --init"
    else:
        echo "Status: √É¬¢√Ö‚Äú√¢‚Ç¨¬¶ Enabled"
        echo &"Provider: {conf.provider.providerName}"
        echo &"Model: {conf.model}"
        echo &"API Key: {'*'.repeat(min(8, conf.apiKey.len))}..."
        echo &"Max Tool Calls: {conf.policy.maxToolCalls}"
        echo &"Timeout: {conf.policy.timeoutMinutes} minutes"
        echo &"Workspace: {conf.workspaceDir}"
        echo &"Show Tool Calls: {conf.showToolCalls}"
        echo &"Confirm Destructive: {conf.confirmDestructive}"
#         echo &"Prompt Cache Key: {conf.promptCacheKey}"
        echo &"Cache Retention: {cacheRetentionToString(conf.promptCacheRetention)}"
        echo &"CodeAct: √É¬¢√Ö‚Äú√¢‚Ç¨¬¶ Enabled"
        if conf.staticContext.len > 0:
            echo &"Static Context: √É¬¢√Ö‚Äú√¢‚Ç¨¬¶ Configured"
        echo ""
        echo "Available Tools:"
        echo "  √É¬¢√¢‚Äö¬¨√Ç¬¢ HITL (ask_human) - Ask user for clarification"
        echo "  √É¬¢√¢‚Äö¬¨√Ç¬¢ Time Tools - Scheduling, timestamps, date math"
        echo "  √É¬¢√¢‚Äö¬¨√Ç¬¢ File Tools - CRUD operations in workspace"
        echo "  √É¬¢√¢‚Äö¬¨√Ç¬¢ CodeAct - Python code execution"
        echo "  √É¬¢√¢‚Äö¬¨√Ç¬¢ GLD Tools - Post, download, analyze, queue, account"
        echo ""
        echo "System prompt:"
        echo "  " & conf.systemPrompt.splitLines()[0] & "..."
        echo ""
        echo "Commands:"
        echo "  gld agent              # Start interactive chat"
        echo "  gld agent --init       # Reconfigure"
        echo "  gld agent --help       # Show help"

    echo ""

# -----------------------------------------------------------------------------
# Agent Creation
# -----------------------------------------------------------------------------


proc createAgent*(conf: agent_config.AgentConfig): Agent =
    ## Create and configure an agent instance
    
    # Validate API key before creating agent
    let (isValid, errorMsg) = validateApiKey(conf)
    if not isValid:
        raise newException(ValueError, &"Invalid API key: {errorMsg}")

    # Set up agent configuration with prompt caching and static context
    var agentCfg = llmm.AgentConfig(
        id              : "gld-agent"
        ,name           : AGENT_NAME
        ,role           : AGENT_ROLE
        ,model          : conf.model
        ,systemPrompt   : conf.systemPrompt
        ,instructions   : ""
        ,workspaceDir   : conf.workspaceDir
        ,dbPath         : agentDbPath()
        ,policy         : AgentPolicy(
            maxToolCalls    : conf.policy.maxToolCalls
            ,timeout        : initDuration(minutes = conf.policy.timeoutMinutes)
        )
        # Note: promptCacheRetention, personaContent, staticContext not in current llmm
    )

    # Add GLD-specific tools
    let toolkit = LatelyToolkit()
    for tool in toolkit:
        agentCfg.tools[tool.name] = tool

    # Add HITL (Human-in-the-Loop) tool for asking user clarification
    let hitlTool = HITLTool()
    agentCfg.tools[hitlTool.name] = hitlTool

    # Add time/date tools for scheduling, post timing, etc.
    let timeToolkit = TimeFullToolkit()
    for tool in timeToolkit:
        agentCfg.tools[tool.name] = tool

    # Add file system tools for managing post drafts, configs, etc.
    # Use workspace directory for file operations
    let fileToolkit = FileCrudToolkit(basePath = conf.workspaceDir)
    for tool in fileToolkit:
        agentCfg.tools[tool.name] = tool

    # Note: CodeAct is enabled after agent creation via enableCodeAct()

    # Create agent
    var agent = Agent(cfg: agentCfg)

    # Set up provider with client
    case conf.provider
    of lpOpenAI:
        # Create OpenAI client directly (constructor is commented out in llmm)
        let client = OpenAIClient(
            apiKey  : conf.apiKey
            ,baseUrl : "https://api.openai.com/v1"
        )
        agent.provider = newOpenAIResponsesProvider(client, "openai")
    of lpKimi:
        # Create Kimi client directly (constructor is commented out in llmm)
        # Note: Moonshot API uses https://api.moonshot.ai/v1 (not .cn)
        # The API key must be valid for this endpoint
        let client = KimiClient(
            apiKey  : conf.apiKey.strip()
            ,baseUrl : "https://api.moonshot.ai/v1"
        )
        agent.provider = newKimiChatProvider(client, "kimi")

    # Initialize agent (creates SQLite stores, etc.)
    discard agent.new()

    # Enable CodeAct runtime - sets up Python environment
    agent.enableCodeAct()

    return agent

# -----------------------------------------------------------------------------
# Run Agent Chat
# -----------------------------------------------------------------------------

proc runAgentChat*(firstMsg: string = "") =
    ## Start interactive agent chat REPL
    let conf = loadAgentConfig()

    if not isAgentConfigured(conf):
        echo ""
        echo "√É¬¢√Ö¬°√Ç¬†√É¬Ø√Ç¬∏√≠¬≤Ì≤è  Agent is not configured."
        echo ""
        echo "Run the setup wizard:"
        echo "  gld agent --init"
        echo ""
        return

    # Also need regular GLD config
    let gldConf = loadConfig()
    try:
        discard requireApiKey(gldConf)
    except ValueError as e:
        echo ""
        echo "√É¬¢√Ö¬°√Ç¬†√É¬Ø√Ç¬∏√≠¬≤Ì≤è  GLD not configured. Please run:"
        echo "  gld init"
        echo ""
        return

    echo ""
    echo &"√É¬∞√Ö¬∏√Ç¬§√¢‚Ç¨‚Äú Starting {AGENT_NAME}..."
    echo ""

    try:
        var agent = createAgent(conf)

        # Configure REPL settings
        var settings = defaultSettings()
        settings.showDebug = true  # Show tool calls by default
        settings.showStats = true
        settings.theme = defaultTheme()

        # Start chat REPL
        chatRepl(agent, firstMsg, settings)

    except CatchableError as e:
        echo &"\n√É¬¢√≠¬≤Ì≤ù√Ö‚Äô Error starting agent: {e.msg}"
        echo ""
        echo "Try reconfiguring: gld agent --init"

# -----------------------------------------------------------------------------
# Single-Shot Agent
# -----------------------------------------------------------------------------

proc runAgentSingle*(message: string) =
    ## Execute a single agent command
    let conf = loadAgentConfig()

    if not isAgentConfigured(conf):
        echo ""
        echo "√É¬¢√Ö¬°√Ç¬†√É¬Ø√Ç¬∏√≠¬≤Ì≤è  Agent is not configured. Run: gld agent --init"
        echo ""
        return

    # Also need regular GLD config
    let gldConf = loadConfig()
    try:
        discard requireApiKey(gldConf)
    except ValueError as e:
        echo ""
        echo "√É¬¢√Ö¬°√Ç¬†√É¬Ø√Ç¬∏√≠¬≤Ì≤è  GLD not configured. Please run: gld init"
        echo ""
        return

    echo &"√É¬∞√Ö¬∏√Ç¬§√¢‚Ç¨‚Äú {AGENT_NAME}: {message}"
    echo ""

    try:
        var agent = createAgent(conf)

        # Create initial session if needed
        if agent.state.session.messages.len == 0:
            agent.state.session = newChatSession("Single Shot")
            # Override the generated ID with a unique one for this single shot
            agent.state.session.id = "single-shot-" & $epochTime().int

        # Process the message through the agent
        let response = waitFor agent.chatTurn(message)

        # Display response
        if response.text.len > 0:
            echo response.text

        # Show stats if there were tool calls
        if response.toolCalls.len > 0:
            echo ""
            echo &"√É¬∞√Ö¬∏√¢‚Ç¨≈ì√Ö¬† Used {response.toolCalls.len} tool(s)"

    except CatchableError as e:
        echo &"\n√É¬¢√≠¬≤Ì≤ù√Ö‚Äô Error: {e.msg}"

# -----------------------------------------------------------------------------
# Main Entry Point
# -----------------------------------------------------------------------------

proc runAgent*(args: seq[string]) =
    ## Main entry point for agent command

    # Handle flags
    if hasFlag(args, "--init") or hasFlag(args, "-i"):
        initAgentInteractive()
        return

    if hasFlag(args, "--status") or hasFlag(args, "-s"):
        showAgentStatus()
        return

    if hasFlag(args, "--help") or hasFlag(args, "-h"):
        echo ""
        echo "√É¬∞√Ö¬∏√Ç¬§√¢‚Ç¨‚Äú GLD Agent - Natural language interface for GLD"
        echo ""
        echo "Usage:"
        echo "  gld agent                     # Start interactive chat"
        echo "  gld agent \"your command\"      # Single-shot command"
        echo "  gld agent --init              # Configure agent"
        echo "  gld agent --status            # Show configuration"
        echo "  gld agent --help              # Show this help"
        echo ""
        echo "Examples:"
        echo "  gld agent \"find clips from https://x.com/... for TikTok\""
        echo "  gld agent \"post a thread about AI to Twitter and Threads\""
        echo "  gld agent \"download this video https://...\""
        echo "  gld agent \"check my account health\""
        echo ""
        return

    # Get positional message
    let msgOpt = getPositionalMessage(args)

    if msgOpt.isSome:
        # Single-shot mode
        runAgentSingle(msgOpt.get)
    else:
        # Interactive mode
        runAgentChat()
