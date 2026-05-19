# Prompt Cache Cross-Repo Hit Fix — Stacked PR Decomposition

## Problem

The original PR (bhagirathsinh/prompt-caching) fixes cross-repo and cross-session Anthropic prompt cache misses. The changes are solid but bundled into a single branch with 6 commits that need to be rebased onto a `dev` branch that has diverged by ~2,000 commits. We need to split this into a stack of targeted, reviewable PRs that can be rebased and merged independently.

## Scope

**In scope:**
- Decompose the 6 commits into 4–5 stacked PRs with clear boundaries
- Address reviewer feedback (singleton invalidation, systemSplit fragility, MCP sorting)
- Provide rebase strategy for the large divergence

**Out of scope:**
- New features beyond what the original PR covers
- MCP tool description stability (noted as "doesn't fix" in original)

## Context

### Current Codebase State (as of `prompt-caching` branch)

The branch contains 6 commits:

| # | Commit | Files | Lines |
|---|---|---|---|
| 1 | `c78ce0ebc` Cache audit logging | 2 | +29 |
| 2 | `669fda670` Cache stabilization | 3 | +15/-2 |
| 3 | `fba2aad6a` System prompt split | 8 | +91/-57 |
| 4 | `212709fe1` Bash cwd removal | 3 | +18/-5 |
| 5 | `3bcde3471` 1h TTL | 3 | +86/-4 |
| 6 | `2e02781f4` splitSystemPrompt option | 1 | +12/-7 |

**Merge base with dev:** `13bac9c91` (~2,049 commits behind dev).

### Key Architectural Dependencies

- Commit 3 (system split) changes `InstructionPrompt.system()` return type from `string[]` to `{ global: string[]; project: string[] }`
- Commit 2 (stabilization) touches `instruction.ts` and `system.ts` — must be adapted to the new interface if it comes after commit 3
- Commit 5 (1h TTL) touches `transform.ts` which hasn't changed on dev, so likely low conflict
- Commit 4 (bash cwd) touches `tool/bash.ts` — independent
- Commit 1 (audit) touches `session/index.ts` and `sidebar.tsx` — sidebar may have diverged significantly on dev

## Architecture

### Decomposition Strategy

We split into **5 stacked PRs** ordered by dependency and risk:

```
PR-1  ←  PR-2  ←  PR-3  ←  PR-4  ←  PR-5
(obs)   (tool)   (arch)   (opt)    (opt)
```

**Why this order?**
- Lower-risk, independent PRs first (observability, tool schema)
- Core architectural change in the middle (system split)
- Opt-in enhancements last (stabilization, extended TTL)
- Each PR provides value on its own if merged before successors

---

## Stacked PR Design

### PR 1: Cache Audit Logging (Observability Foundation)

**Branch:** `feat/cache-audit-logging`
**Base:** `dev`
**Commits:** `c78ce0ebc` (manually re-applied)

**Original files:** `session/index.ts`, `sidebar.tsx`
**Current files:** `session/processor.ts`, `cli/cmd/tui/feature-plugins/sidebar/context.tsx`

**Changes to apply:**
1. **`packages/opencode/src/session/processor.ts`** (replaces `session/index.ts`)
   - After `Session.getUsage()` call (~line 486), add:
   ```typescript
   // OPENCODE_CACHE_AUDIT=1 enables per-call cache token accounting in the log
   if (process.env["OPENCODE_CACHE_AUDIT"]) {
     const totalInputTokens = usage.tokens.input + usage.tokens.cache.read + usage.tokens.cache.write
     const cacheHitPercent = totalInputTokens > 0 ? ((usage.tokens.cache.read / totalInputTokens) * 100).toFixed(1) : "0.0"
     log.info(
       `[CACHE] ${ctx.model.id}  input=${totalInputTokens} (cache_read=${usage.tokens.cache.read} cache_write=${usage.tokens.cache.write} new=${usage.tokens.input})  hit=${cacheHitPercent}%  output=${usage.tokens.output}  total=${usage.tokens.total ?? 0}`,
     )
   }
   ```

2. **`packages/opencode/src/cli/cmd/tui/feature-plugins/sidebar/context.tsx`** (replaces direct `sidebar.tsx` modification)
   - The sidebar now uses plugin slots. Add cache audit display conditionally:
   ```tsx
   <Show when={process.env["OPENCODE_CACHE_AUDIT"] && state().cacheHitPercent != null}>
     <box>
       <text fg={theme().text}><b>Cache Audit</b></text>
       <text fg={theme().textMuted}>{state().cacheInput.toLocaleString()} input tokens</text>
       <text fg={theme().textMuted}>  {state().cacheNew.toLocaleString()} new</text>
       <text fg={theme().textMuted}>  {state().cacheRead.toLocaleString()} cache read</text>
       <text fg={theme().textMuted}>  {state().cacheWrite.toLocaleString()} cache write</text>
       <text fg={theme().textMuted}>{state().cacheHitPercent}% hit rate</text>
       <text fg={theme().textMuted}>{state().cacheOutput.toLocaleString()} output tokens</text>
     </box>
   </Show>
   ```
   - Update `state()` memo to compute cache fields

**Risk:** Medium. Both files have diverged significantly from original.

**Testing:** `OPENCODE_CACHE_AUDIT=1 bun dev`, verify log output and sidebar rendering.

---

### PR 2: Bash Tool Schema Stability

**Branch:** `fix/bash-tool-schema-cache`
**Base:** `dev` (independent of PR-1)
**Commits:** `212709fe1` (code already on dev; only test needs adding)

**Original files:** `tool/bash.ts`, `tool/bash.txt`, `test/tool/bash.test.ts`
**Current files:** `tool/shell.ts`, `tool/shell/prompt.ts`, `tool/shell/shell.txt`, `test/tool/shell.test.ts`

**Status:** The code changes (removing `Instance.directory` from schema descriptions) are **already applied** on dev in the new `tool/shell/prompt.ts`. Only the test needs to be added.

**Changes to apply:**
1. **`packages/opencode/test/tool/shell.test.ts`** (replaces `bash.test.ts`)
   - Add test:
   ```typescript
   test("tool schema does not contain Instance.directory for stable cache hash", async () => {
     await Instance.provide({
       directory: projectRoot,
       fn: async () => {
         const shell = await ShellTool.init()
         expect(shell.description).not.toContain(Instance.directory)
         const schema = JSON.stringify(shell.parameters)
         expect(schema).not.toContain(Instance.directory)
       },
     })
   })
   ```

**Risk:** Low. Only adding a test.

**Testing:** `bun test packages/opencode/test/tool/shell.test.ts`

---

### PR 3: System Prompt Split (Core Architecture)

**Branch:** `feat/system-prompt-split`
**Base:** `dev` (depends on PR-1 and PR-2 conceptually, but not technically)
**Commits:** `fba2aad6a` + `2e02781f4` (squashed or kept separate)

**Changes:**
- `packages/opencode/src/session/instruction.ts` — split into `global`/`project` scopes
- `packages/opencode/src/session/system.ts` — split skills into `global`/`project`
- `packages/opencode/src/session/prompt.ts` — build ordered system array, compute `systemSplit`
- `packages/opencode/src/session/llm.ts` — split into 2 blocks, add `splitSystemPrompt` provider option
- `packages/opencode/src/skill/index.ts` — pass scope through skill loading
- Tests updated

**Risk:** Medium. Core prompt architecture; any change to message ordering on dev will conflict.

**Reviewer feedback to address:**

#### 3a. systemSplit fragility

**Current:** `systemSplit = instructions.global.length + (skills.global ? 1 : 0)`
**Problem:** Assumes fixed array ordering. Future reordering breaks cache markers.
**Recommended fix:** Make split explicit.

```typescript
// session/prompt.ts
export type SystemBlocks = {
  stable: string[]   // global instructions + global skills
  dynamic: string[]  // env + project skills + project instructions
}

// Instead of:
const system = [...]
const systemSplit = N

// Use:
const system = {
  stable: [...instructions.global, ...(skills.global ? [skills.global] : [])],
  dynamic: [...(await SystemPrompt.environment(model)), ...(skills.project ? [skills.project] : []), ...instructions.project],
}
```

Then in `llm.ts`:
```typescript
const system = shouldSplit
  ? [
      [...prompt, ...input.system.stable].filter(Boolean).join("\n"),
      [...input.system.dynamic, ...(input.user.system ? [input.user.system] : [])].filter(Boolean).join("\n"),
    ].filter(Boolean)
  : [...]
```

This removes the positional `systemSplit` entirely and makes the split self-documenting.

#### 3b. splitSystemPrompt option

Already included in commit 6. Keep it in this PR as an escape hatch.

**Testing:**
- `bun test packages/opencode/test/session/instruction.test.ts`
- `bun test packages/opencode/test/session/system.test.ts`
- `bun test packages/opencode/test/provider/transform.test.ts`
- Manual: verify 2 system blocks in Anthropic requests

---

### PR 4: Cache Stabilization (Opt-in Enhancement)

**Branch:** `feat/cache-stabilization`
**Base:** `feat/system-prompt-split` (PR-3)
**Commits:** `669fda670` (adapted to new interfaces)

**Changes:**
- `packages/opencode/src/flag/flag.ts` — add `OPENCODE_EXPERIMENTAL_CACHE_STABILIZATION`
- `packages/opencode/src/session/instruction.ts` — cache instruction reads for process lifetime
- `packages/opencode/src/session/system.ts` — freeze date on first access

**Risk:** Low. Behind env var flag.

**Reviewer feedback to address:**

#### 4a. Module-level singletons lack invalidation

**Current:**
```typescript
let cachedDate: Date | undefined
let cached: SystemInstructions | undefined
```

**Problem:** Tests that change date/instructions get stale data. User editing AGENTS.md mid-session won't see updates.

**Recommended fix:** Export `clearCache()` for tests and potential future use.

```typescript
// session/instruction.ts
export function clearCache() {
  cached = undefined
}

// session/system.ts
export function clearCache() {
  cachedDate = undefined
}
```

This is minimal and doesn't change the default behavior. Tests can call it in `beforeEach`.

**Testing:**
- Unit tests with flag on/off
- Verify date stays frozen across multiple `environment()` calls
- Verify instructions are cached across `system()` calls

---

### PR 5: Extended Cache TTL (Optimization)

**Branch:** `feat/cache-extended-ttl`
**Base:** `feat/system-prompt-split` (PR-3) or `feat/cache-stabilization` (PR-4)
**Commits:** `3bcde3471`

**Changes:**
- `packages/opencode/src/flag/flag.ts` — add `OPENCODE_EXPERIMENTAL_CACHE_1H_TTL`
- `packages/opencode/src/provider/transform.ts` — apply 1h TTL to first system cache marker
- `packages/opencode/test/provider/transform.test.ts` — extended TTL tests

**Risk:** Low. Behind env var flag.

**Reviewer feedback to address:**

#### 5a. 1h TTL as env var vs config

**Current:** Only env var `OPENCODE_EXPERIMENTAL_CACHE_1H_TTL`.
**Suggestion:** Also support `provider.<id>.options.extendedTTL: true` in `opencode.json`.

**Decision:** This is a nice-to-have. Can be added in a follow-up or included here if trivial. The env var is sufficient for experimentation.

**Testing:** `bun test packages/opencode/test/provider/transform.test.ts`

---

## Alternative: 4-PR Stack

If PR-4 and PR-5 are small enough, they can be combined:

```
PR-1: Cache audit logging
PR-2: Bash tool schema fix
PR-3: System prompt split + splitSystemPrompt option
PR-4: Cache stabilization + extended TTL (both behind flags)
```

**Trade-off:** PR-4 would be ~20 lines across 4 files — still small and reviewable. This reduces stack height by 1.

---

## Conflict Analysis

Cherry-pick attempts revealed severe divergence — files renamed, deleted, or heavily rewritten.

| PR | Commit | Result | Files Affected |
|---|---|---|---|
| PR-1 | `c78ce0ebc` | **Failed** (modify/delete) | `session/index.ts` deleted; `sidebar.tsx` rewritten |
| PR-2 | `212709fe1` | **Failed** (modify/delete) | `tool/bash.ts` → `tool/shell.ts`; `bash.txt` → `shell/shell.txt`; test renamed |
| PR-3 | `fba2aad6a` | **8 content conflicts** | `instruction.ts`, `system.ts`, `prompt.ts`, `llm.ts`, `skill/index.ts`, tests |

**Key file renames on dev:**
- `session/index.ts` → deleted (refactored into `session/llm.ts`, `session/session.ts`, `session/processor.ts`)
- `tool/bash.ts` → `tool/shell.ts` + `tool/shell/` directory
- `tool/bash.txt` → `tool/shell/shell.txt`
- `test/tool/bash.test.ts` → `test/tool/shell.test.ts`
- `sidebar.tsx` → completely rewritten with plugin slot architecture

### PR-2 Code Already on Dev

The bash schema fix (removing `Instance.directory` from descriptions) is **already applied** in the new `tool/shell/prompt.ts`. Only the **test** needs to be added to `shell.test.ts`.

---

## Rebase Strategy

Given ~2,049 commits of divergence, cherry-pick is not viable. Instead:

1. **Create each PR branch from fresh `dev`** in an isolated worktree
2. **Manually re-apply** each PR's changes to the current file structure
3. **Create fresh commits** with co-author attribution
4. **Run tests after each PR** to catch issues early
5. **Execute sequentially** (1 → 2 → 3 → 4 → 5) since PR-4/5 depend on PR-3

### Sequential Workflow

```bash
# PR-1: Manually apply cache audit changes
cd .worktrees/pr-1-cache-audit
git checkout -f dev && git clean -fd
# Apply: processor.ts (add [CACHE] log), sidebar/context.tsx (add cache audit display)
git add -A && git commit -m "feat(cache): add cache token audit logging..." --author="..."

# PR-2: Add schema stability test (code already on dev)
cd .worktrees/pr-2-bash-schema
git checkout -f dev && git clean -fd
# Apply: shell.test.ts (add test)
git add -A && git commit -m "fix(cache): remove cwd from bash tool schema..." --author="..."

# PR-3: Resolve all 8 file conflicts
cd .worktrees/pr-3-system-split
git checkout -f dev && git clean -fd
# Apply: instruction.ts, system.ts, prompt.ts, llm.ts, skill/index.ts, tests
git add -A && git commit -m "fix(cache): split system prompt..." --author="..."

# PR-4: Cherry-pick stabilization onto PR-3 branch
cd .worktrees/pr-4-cache-stabilization
git checkout -f dev && git clean -fd
# Apply: flag.ts, instruction.ts, system.ts
git add -A && git commit -m "fix(cache): stabilize system prefix..." --author="..."

# PR-5: Cherry-pick TTL onto PR-3 branch
cd .worktrees/pr-5-cache-ttl
git checkout -f dev && git clean -fd
# Apply: flag.ts, transform.ts, tests
git add -A && git commit -m "feat(cache): add optional 1h TTL..." --author="..."
```

### Conflict Hotspots

| File | Divergence Risk | Mitigation |
|---|---|---|
| `session/index.ts` | High (active development) | PR-1 may need manual re-application |
| `sidebar.tsx` | High (UI churn) | PR-1 may need manual re-application |
| `session/llm.ts` | Medium | PR-3 core logic is additive; likely applies cleanly |
| `session/prompt.ts` | Medium | PR-3 may conflict if message ordering changed on dev |
| `provider/transform.ts` | Low | PR-5 likely applies cleanly |
| `tool/bash.ts` | Low | PR-2 likely applies cleanly |

---

## Co-author Attribution

Each commit should include the original author:

```
Co-authored-by: Bhagirathsinh Vaghela <bhagirathsinh.vaghela.001@gmail.com>
```

If cherry-picking with `-x`, Git preserves the original author automatically.

---

## Decisions

| Question | Decision |
|---|---|
| Address reviewer feedback? | **No** — keep original commits as-is, focus purely on decomposition |
| 4 PRs or 5 PRs? | **5 PRs** — laser-focused, easier to review |
| Cherry-pick or manual re-apply? | **Manual re-application** — cherry-pick failed due to file renames/deletions (see Conflict Analysis) |
| Workspace isolation? | **Git worktree per PR** — isolated directories, no stashing needed |
| Execution order? | **Sequential (1 → 2 → 3 → 4 → 5)** — PR-4/5 depend on PR-3 |

---

## Worktree Layout

Main repo: `/Users/martinrichards/code/opencode` (branch `dev`)
Worktrees directory: `.worktrees/` (already gitignored)

| PR | Worktree Path | Branch | Base |
|---|---|---|---|
| 1 | `.worktrees/pr-1-cache-audit/` | `feat/cache-audit-logging` | `dev` |
| 2 | `.worktrees/pr-2-bash-schema/` | `fix/bash-tool-schema-cache` | `dev` |
| 3 | `.worktrees/pr-3-system-split/` | `feat/system-prompt-split` | `dev` |
| 4 | `.worktrees/pr-4-cache-stabilization/` | `feat/cache-stabilization` | PR-3 branch |
| 5 | `.worktrees/pr-5-cache-ttl/` | `feat/cache-extended-ttl` | PR-3 branch |

---

## Implementation Plan

### Phase 1: Rebase Preparation

**T1: Verify dev branch is up to date**
- `cd /Users/martinrichards/code/opencode && git checkout dev && git pull upstream dev`
- Confirm no local changes on `dev`

**T2: Identify cherry-pick order**
- Commits must be cherry-picked in dependency order (1 → 2 → 3 → 6 → 4 → 5)
- Note: commit 6 (`splitSystemPrompt`) depends on commit 3's `systemSplit` field, so 6 comes after 3

### Phase 2: Create Worktrees and PR Branches

All commands run from main repo: `/Users/martinrichards/code/opencode`

**T3: PR-1 — Cache Audit Logging**
```bash
git worktree add .worktrees/pr-1-cache-audit -b feat/cache-audit-logging dev
cd .worktrees/pr-1-cache-audit
git cherry-pick c78ce0ebc
# resolve conflicts if sidebar.tsx diverged
bun test
# push when ready
git push -u origin feat/cache-audit-logging
```
- Files: `session/index.ts`, `sidebar.tsx`
- Risk: `sidebar.tsx` has diverged; may need manual conflict resolution

**T4: PR-2 — Bash Tool Schema Fix**
```bash
git worktree add .worktrees/pr-2-bash-schema -b fix/bash-tool-schema-cache dev
cd .worktrees/pr-2-bash-schema
git cherry-pick 212709fe1
bun test test/tool/bash.test.ts
git push -u origin fix/bash-tool-schema-cache
```
- Files: `tool/bash.ts`, `tool/bash.txt`, `test/tool/bash.test.ts`
- Risk: Low

**T5: PR-3 — System Prompt Split**
```bash
git worktree add .worktrees/pr-3-system-split -b feat/system-prompt-split dev
cd .worktrees/pr-3-system-split
git cherry-pick fba2aad6a
# resolve conflicts
git cherry-pick 2e02781f4
# resolve conflicts
bun test
git push -u origin feat/system-prompt-split
```
- Files: `instruction.ts`, `system.ts`, `prompt.ts`, `llm.ts`, `skill/index.ts`, tests
- Risk: Medium — core prompt architecture

**T6: PR-4 — Cache Stabilization**
```bash
git worktree add .worktrees/pr-4-cache-stabilization -b feat/cache-stabilization feat/system-prompt-split
cd .worktrees/pr-4-cache-stabilization
git cherry-pick 669fda670
# may conflict with PR-3's instruction.ts changes; adapt if needed
bun test
git push -u origin feat/cache-stabilization
```
- Files: `flag/flag.ts`, `session/instruction.ts`, `session/system.ts`
- Risk: Low

**T7: PR-5 — Extended Cache TTL**
```bash
git worktree add .worktrees/pr-5-cache-ttl -b feat/cache-extended-ttl feat/system-prompt-split
cd .worktrees/pr-5-cache-ttl
git cherry-pick 3bcde3471
bun test test/provider/transform.test.ts
git push -u origin feat/cache-extended-ttl
```
- Files: `flag/flag.ts`, `provider/transform.ts`, `test/provider/transform.test.ts`
- Risk: Low

### Phase 3: Validation

**T8: Run tests in each worktree**
- `cd .worktrees/pr-N-*/packages/opencode && bun test` for each PR
- Fix any failures before pushing

**T9: Verify co-author attribution**
```bash
for wt in .worktrees/pr-*; do
  echo "=== $wt ==="
  git -C "$wt" log dev..HEAD --format="%H %an <%ae>"
done
```
- Confirm Bhagirathsinh Vaghela is author on all commits

### Cleanup

After PRs are merged:
```bash
for wt in .worktrees/pr-*; do
  git worktree remove "$wt"
done
```

### Conflict Escalation

If a cherry-pick has conflicts in more than 3 files, abort and switch to manual re-application within the worktree:
```bash
git cherry-pick --abort
# Manually apply changes from original commit
git add -A && git commit -m "..." --author="Bhagirathsinh Vaghela <bhagirathsinh.vaghela.001@gmail.com>"
```
