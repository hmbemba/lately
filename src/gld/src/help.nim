import
    termui

proc printHelp*() =
    echo ""
    echo "  ✨ GLD CLI - Social Media Management"
    echo "  ==================================="
    echo "  The official CLI for Late.dev. Schedule, queue, and publish"
    echo "  content across all your social platforms from the terminal."
    echo ""

    echo "  🚀 CORE COMMANDS"
    termuiLabel("gld init", "Configure API key and default profile")
    termuiLabel("gld post", "Create posts (Interactive or Flags)")
    termuiLabel("gld queue", "Manage posting schedules & slots")
    termuiLabel("gld accounts", "View connected platform health")
    termuiLabel("gld profiles", "Manage multiple brand profiles")
    termuiLabel("gld uploads", "View your media upload history")
    termuiLabel("gld sched", "List currently scheduled posts")
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
    echo "  1. Interactive Post (Recommended)"
    echo "     $ gld post"
    echo "     > Prompts for text, media, and platforms."
    echo ""
    echo "  2. Quick Update"
    echo "     $ gld x \"Shipping new features today! 📦\""
    echo ""
    echo "  3. Post with Media"
    echo "     $ gld ig \"Office view\" --file ./photo.jpg"
    echo ""
    echo "  4. Add to Queue (Auto-schedule)"
    echo "     $ gld post \"Weekly tip...\" --queue --to x,li"
    echo ""
    echo "  5. Schedule Specific Time"
    echo "     $ gld post \"Launch time\" --schedule \"2025-01-01T12:00:00\""
    echo ""
    echo "  6. Switch Profiles"
    echo "     $ gld post --profile <my_alt_profile>"
    echo ""

    echo "  Use 'gld <command> --help' for detailed flags (e.g., 'gld post --help')"
    echo ""