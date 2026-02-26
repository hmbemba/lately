# GLD Agent & Interactive Commands - Implementation Plan

## Current Status

✅ `gld ideas` feature is complete and working  
❌ `agent` and `interactive` commands are disabled in `gld.nim`  
❌ Imports for `cmd_agent` and `cmd_interactive` are commented out throughout  
✅ User confirmed llmm framework is back to latest version  

**Correction**: The fields `promptCacheRetention`, `personaContent`, `staticContext` **DO** exist in the latest llmm `AgentConfig`. Previous assessment was incorrect.

---

## Goal

Re-enable and fix `gld agent` and `gld interactive` commands to work with the current llmm API.

---

## Phase 1: What's Actually Needed

### 1.1 Re-enable Commands in gld.nim

The main issue is simply that commands are disabled:

```nim
# Currently commented out in gld.nim:
import ./src/cmd_interactive
import ./src/cmd_agent

# And:
of "i", "interactive":
    # echo "temporarily disabled"
    runInteractive()

of "agent", "a", "ai":
    # echo "temporarily disabled"
    runAgent(rest)

# And no-args case:
if args.len == 0:
    runInteractive()  # instead of disabled message
```

### 1.2 Verify cmd_agent.nim Works

Since the `AgentConfig` fields exist in llmm, the main issues to check are:

| Check | Why |
|-------|-----|
| Import paths | `llmm/harness/tools/...` vs `llmm/tools` |
| Provider creation | Signature of `newKimiChatProvider`, `newOpenAIResponsesProvider` |
| `agent.new()` call | Ensure initialization pattern matches |
| `chatRepl()` signature | Check parameters match current API |
| `chatTurn()` signature | Check return type and parameters |
| Trailing discard block | Remove the `discard """nim c...` block at file end |

### 1.3 Verify cmd_interactive.nim Works

| Check | Why |
|-------|-----|
| Import paths | Ensure `cmd_agent` import works once re-enabled |
| `isAgentConfigured()` | Verify this function exists and works |
| `initAgentInteractive()` | Verify this function exists and works |

---

## Phase 2: Implementation Steps

### Step 2.1: Fix cmd_agent.nim (if needed)

**File**: `src/gld/src/cmd_agent.nim`

Changes likely needed:
1. **Verify imports** - Check paths match current llmm structure
2. **Check provider creation** - May need to update call signatures
3. **Check agent initialization** - Verify `agent.new()` pattern
4. **Check chatRepl signature** - Ensure parameters are correct
5. **Check chatTurn signature** - Ensure return type handling is correct
6. **Remove trailing discard block** - Clean up the compile commands at end

**Key APIs to verify** (from llmm's agent.nim):
```nim
# Agent constructor pattern
var a = new Agent(
    provider: someProvider,
    cfg: AgentConfig(...)
)

# Then initialize
discard a.new()  # or just a.new()

# Add tools
a.addTools @[...]

# Enable CodeAct
a.enableCodeAct()

# Start REPL
a.chatRepl()

# Single turn
let result = await agent.chatTurn(message)
```

### Step 2.2: Verify cmd_interactive.nim

**File**: `src/gld/src/cmd_interactive.nim`

Changes likely needed:
1. **Verify imports** at top of file
2. **Verify cmd_agent import** works
3. **Test ActionAgent flow** - ensure agent integration works

### Step 2.3: Re-enable Commands in gld.nim

**File**: `src/gld/gld.nim`

Changes needed:
1. **Uncomment imports** (~line 15-16):
   ```nim
   import ./src/cmd_interactive
   import ./src/cmd_agent
   ```

2. **Uncomment command dispatch**:
   ```nim
   of "i", "interactive":
       runInteractive()
   
   of "agent", "a", "ai":
       runAgent(rest)
   ```

3. **Fix no-args case** (~line 28):
   ```nim
   if args.len == 0:
       runInteractive()
       return
   ```

---

## Phase 3: Testing & Verification

### 3.1 Compile Tests

```bash
# Test compilation of gld
nim c -d:ssl --check src/gld/gld.nim

# If successful, full compile
nim c -d:ssl -d:release src/gld/gld.nim
```

### 3.2 Runtime Tests

```bash
# Test help still works
./gld help

# Test interactive (should show menu)
./gld interactive

# Test agent status (should show config status or prompt for init)
./gld agent --status

# Test agent init (interactive setup)
./gld agent --init
```

---

## Phase 4: Specific Investigation Points

Since the AgentConfig fields exist, the real work is:

### File: src/gld/src/cmd_agent.nim

**Investigate**:
- Provider creation calls - do they match current llmm signatures?
- `chatRepl` call - what are its parameters?
- `chatTurn` call - what's its return type?
- Is the trailing discard block causing issues?

### File: src/gld/src/cmd_interactive.nim

**Investigate**:
- Are imports correct for current llmm?
- Does ActionAgent integration work?

### File: src/gld/gld.nim

**Changes**:
- Just uncomment the disabled code

---

## Estimated Effort (Revised)

| Task | Estimated Time |
|------|---------------|
| Verify cmd_agent.nim with current llmm | 20 min |
| Fix any API mismatches in cmd_agent.nim | 30 min |
| Verify cmd_interactive.nim | 10 min |
| Re-enable commands in gld.nim | 5 min |
| Testing & debugging | 20 min |
| **Total** | **~85 min** |

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Provider creation API changed | Medium | Check actual llmm provider files |
| chatRepl/chatTurn signatures changed | Medium | Verify in llmm/harness/primitives/agent.nim |
| Tools import paths changed | Low | Easy to fix |
| Other llmm API changes | Low | Compile and fix errors |

---

## Success Criteria

- [ ] `gld` (no args) launches interactive mode
- [ ] `gld interactive` launches interactive mode  
- [ ] `gld agent --status` shows agent configuration
- [ ] `gld agent --init` runs interactive setup
- [ ] `gld agent "test message"` runs single-shot agent
- [ ] `gld agent` starts interactive chat REPL
- [ ] All existing commands still work (`gld ideas`, `gld post`, etc.)

---

## Quick Start Command

When ready to implement:

```bash
# 1. Read current cmd_agent.nim to check for API issues
cat src/gld/src/cmd_agent.nim

# 2. Read current cmd_interactive.nim
cat src/gld/src/cmd_interactive.nim

# 3. Try compiling gld to see actual errors
nim c -d:ssl src/gld/gld.nim

# 4. Fix any compilation errors

# 5. Re-enable commands in gld.nim
```
