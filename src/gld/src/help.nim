import
    termui

proc printHelp*() =
    echo ""
    echo "  ✨ GLD CLI - Social Media Management"
    echo "  ==================================="
    echo "  The official CLI for Late.dev. Schedule, queue, and publish"
    echo "  content across all your social platforms from the terminal."
    echo ""

    echo "  🤖 AGENT (AI-POWERED)"
    termuiLabel("gld agent", "Natural language interface (interactive chat)")
    termuiLabel("gld agent \"<cmd>\"", "Single-shot natural language command")
    termuiLabel("gld agent --init", "Configure the AI agent")
    termuiLabel("gld agent --status", "Show agent configuration")
    echo ""

    echo "  🚀 CORE COMMANDS"
    termuiLabel("gld init", "Configure API key and default profile")
    termuiLabel("gld config", "Configure download providers and settings")
    termuiLabel("gld post", "Create posts (Interactive or Flags)")
    termuiLabel("gld thread", "Create X/Threads multi-tweet threads")
    termuiLabel("gld queue", "Manage posting schedules & slots")
    termuiLabel("gld accounts", "View connected platform health")
    termuiLabel("gld profiles", "Manage multiple brand profiles")
    termuiLabel("gld uploads", "View your media upload history")
    termuiLabel("gld sched", "List currently scheduled posts")
    termuiLabel("gld download", "Download media from social platforms")
    termuiLabel("gld ideas", "Capture and manage your ideas (local SQLite)")
    echo ""

    echo "  ⚡ PLATFORM SHORTCUTS"
    termuiLabel("gld x", "Post to X / Twitter")
    termuiLabel("gld threads", "Post to Threads")
    termuiLabel("gld ig", "Post to Instagram")
    termuiLabel("gld li", "Post to LinkedIn")
    termuiLabel("gld fb", "Post to Facebook")
    termuiLabel("gld tiktok", "Post to TikTok")
    termuiLabel("gld yt", "Post to YouTube")
    termuiLabel("gld bluesky", "Post to Bluesky")
    echo ""

    echo "  💡 USAGE EXAMPLES"
    echo ""
    echo "  1. Agent Natural Language"
    echo "     $ gld agent \"find clips from https://x.com/... for TikTok\""
    echo ""
    echo "  2. Interactive Post (Recommended)"
    echo "     $ gld post"
    echo "     > Prompts for text, media, and platforms."
    echo ""
    echo "  3. Quick Update"
    echo "     $ gld x \"Shipping new features today! 📦\""
    echo ""
    echo "  4. Post with Media"
    echo "     $ gld ig \"Office view\" --file ./photo.jpg"
    echo ""
    echo "  5. Add to Queue (Auto-schedule)"
    echo "     $ gld post \"Weekly tip...\" --queue --to x,li"
    echo ""
    echo "  6. Schedule Specific Time"
    echo "     $ gld post \"Launch time\" --schedule \"2025-01-01T12:00:00\""
    echo ""
    echo "  7. Switch Profiles"
    echo "     $ gld post --profile <my_alt_profile>"
    echo ""

    echo "  Use 'gld <command> --help' for detailed flags (e.g., 'gld post --help')"
    echo ""
