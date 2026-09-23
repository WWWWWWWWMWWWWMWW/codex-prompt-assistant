# Simplified Dynamic Expression Library Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task.

**Goal:** Build an encrypted, rebuildable local expression library from repeated user sentences and use it to replace the fixed Phase 0 suggestion with a real prefix completion.

**Architecture:** Raw encrypted messages remain the source of truth. A versioned builder streams decrypted user messages through a conservative sentence extractor, atomically replaces encrypted derived expression rows while preserving tombstones, and publishes an immutable in-memory prefix index only after a successful rebuild.

**Tech Stack:** Objective-C, Foundation, SQLite3, CommonCrypto, existing AppKit/Accessibility candidate bar, Clang Makefile.

---

## MVP boundaries

- User messages only; no AI learning or feedback scoring.
- Exact normalized sentences only; no templates, semantic search, FTS5 or vectors.
- Rebuild after a successful manual data scan; no directory watcher yet.
- Synthetic fixtures only; no real chat import and no network.

### Task 1: Stream decrypted user-message records

**Files:**
- Create: `Sources/CodexDataCore/LocalUserMessageRecord.h`
- Create: `Sources/CodexDataCore/LocalUserMessageRecord.m`
- Modify: `Sources/CodexDataCore/LocalDataStore.h`
- Modify: `Sources/CodexDataCore/LocalDataStore.m`
- Modify: `Tests/CodexDataCoreTests/LocalDataStoreTests.m`

**Step 1: Write the failing test**

Add a database containing user and assistant messages across two conversations. Enumerate user records and assert the callback receives only user text plus numeric message/conversation IDs, source timestamp and the existing sensitive-hit flag. Assert enumeration order is stable by message row ID and callback cancellation stops cleanly.

Proposed API:

```objc
typedef BOOL (^CPALocalUserMessageHandler)(
    CPALocalUserMessageRecord *record, BOOL *stop, NSError **error);

- (BOOL)enumerateDecryptedUserMessages:(CPALocalUserMessageHandler)handler
    error:(NSError **)error;
```

**Step 2: Run the test to verify it fails**

Run: `make data-core-test`
Expected: compile failure because `CPALocalUserMessageRecord` and the enumeration API do not exist.

**Step 3: Implement the minimal streaming API**

Prepare one ordered SQLite statement joining `messages` and `conversations` with `role='user'`. Step one row at a time, decrypt one envelope, call the handler inside a small autorelease pool, and never log text. Convert `redaction_counts_json != '{}'` into `containsSensitiveData` without exposing the redacted values.

**Step 4: Run focused and full tests**

Run: `make data-core-test`
Expected: all data-core tests print `PASS`.

**Step 5: Commit**

```bash
git add Sources/CodexDataCore Tests/CodexDataCoreTests
git commit -m "feat: stream decrypted user messages locally"
```

### Task 2: Add the conservative fixed-sentence extractor

**Files:**
- Create: `Sources/ExpressionLibraryCore/ExpressionExtractor.h`
- Create: `Sources/ExpressionLibraryCore/ExpressionExtractor.m`
- Create: `Tests/ExpressionLibraryCoreTests/ExpressionExtractorTests.m`
- Modify: `Makefile`

**Step 1: Write the failing extractor tests**

Cover Chinese and English sentence splitting, newlines, repeated whitespace, 4/160 character boundaries, sensitive-message exclusion, code fences, URLs, absolute paths, JSON-like text and log prefixes. Include positive fixtures such as `先别急着做，先把方案梳理清楚` and negative fixtures containing only code or secrets.

Proposed API:

```objc
@interface CPAExtractedExpression : NSObject
@property(nonatomic, copy, readonly) NSString *normalizedText;
@end

@interface CPAExpressionExtractor : NSObject
- (NSArray<CPAExtractedExpression *> *)expressionsFromText:(NSString *)text
    containsSensitiveData:(BOOL)containsSensitiveData;
@end
```

**Step 2: Verify red**

Run: `make expression-library-test`
Expected: compile failure because the extractor does not exist.

**Step 3: Implement only fixed-sentence rules**

Use Foundation string scanning and regular expressions already available on macOS. Do not add tokenizers or dependencies. Keep punctuation in the display text, collapse internal whitespace, and return deterministic ordering without near-duplicate merging.

**Step 4: Verify green**

Run: `make expression-library-test`
Expected: `PASS: ExpressionExtractorTests`.

**Step 5: Commit**

```bash
git add Sources/ExpressionLibraryCore Tests/ExpressionLibraryCoreTests Makefile
git commit -m "feat: extract safe repeated sentence candidates"
```

### Task 3: Add schema v4 and atomic encrypted expression replacement

**Files:**
- Create: `Sources/CodexDataCore/LocalExpressionRecord.h`
- Create: `Sources/CodexDataCore/LocalExpressionRecord.m`
- Modify: `Sources/CodexDataCore/Schema.sql`
- Modify: `Sources/CodexDataCore/LocalDataStore.h`
- Modify: `Sources/CodexDataCore/LocalDataStore.m`
- Modify: `Tests/CodexDataCoreTests/LocalDataStoreTests.m`

**Step 1: Write failing persistence tests**

Assert schema v3 migrates to v4 and creates `expressions`, `expression_occurrences`, `expression_tombstones` and `expression_builds`. Replace two active expressions in one transaction, load them decrypted, and scan SQLite/WAL/SHM to prove neither expression text appears in plaintext. Simulate a failed replacement and assert the previous expression set remains intact.

Proposed high-level store API:

```objc
- (nullable CPALocalExpressionBuildResult *)replaceActiveExpressions:
    (NSArray<CPALocalExpressionCandidate *> *)expressions
    extractorVersion:(NSUInteger)extractorVersion
    error:(NSError **)error;

- (nullable NSArray<CPALocalExpressionRecord *> *)loadActiveExpressions:
    (NSError **)error;
```

**Step 2: Verify red**

Run: `make data-core-test`
Expected: migration/table/API assertions fail.

**Step 3: Implement encrypted storage**

Within `BEGIN IMMEDIATE`, clear only rebuildable expression rows, preserve tombstones, compute a domain-separated HMAC-SHA256 digest from normalized UTF-8 text, skip tombstoned digests, encrypt expression bodies with `CPAMessageCrypto`, insert occurrence links and a count-only build record, then commit. Any error rolls back to the previous complete set.

**Step 4: Verify green and plaintext absence**

Run: `make data-core-test`
Expected: all tests pass; synthetic expression plaintext matches in database artifacts equal zero.

**Step 5: Commit**

```bash
git add Sources/CodexDataCore Tests/CodexDataCoreTests
git commit -m "feat: persist encrypted expression snapshots"
```

### Task 4: Build expressions from cross-conversation repetition

**Files:**
- Create: `Sources/ExpressionLibraryCore/ExpressionLibraryBuilder.h`
- Create: `Sources/ExpressionLibraryCore/ExpressionLibraryBuilder.m`
- Create: `Tests/ExpressionLibraryCoreTests/ExpressionLibraryBuilderTests.m`
- Modify: `Makefile`

**Step 1: Write failing builder tests**

Create synthetic records where one sentence occurs in two conversations, another repeats only within one conversation, one appears only in assistant messages and one is sensitive/code noise. Assert only the cross-conversation user sentence becomes active, counts and last timestamp are correct, and three rebuilds remain idempotent.

**Step 2: Verify red**

Run: `make expression-library-test`
Expected: compile failure because the builder is missing.

**Step 3: Implement the deterministic builder**

Stream user messages from `CPALocalDataStore`, extract sentences, aggregate by normalized text in memory, track a set of conversation row IDs and message row IDs, keep candidates with at least two conversations, sort deterministically, and call the atomic replacement API. Never count a generated suggestion as a source occurrence.

**Step 4: Verify green**

Run: `make expression-library-test data-core-test`
Expected: all expression and data tests pass.

**Step 5: Commit**

```bash
git add Sources/ExpressionLibraryCore Tests/ExpressionLibraryCoreTests Makefile
git commit -m "feat: rebuild repeated user expressions"
```

### Task 5: Preserve expression deletion through rebuilds

**Files:**
- Modify: `Sources/CodexDataCore/LocalDataStore.h`
- Modify: `Sources/CodexDataCore/LocalDataStore.m`
- Modify: `Tests/ExpressionLibraryCoreTests/ExpressionLibraryBuilderTests.m`
- Modify: `Tests/CodexDataCoreTests/LocalDataStoreTests.m`

**Step 1: Write failing deletion tests**

Delete an active expression by its normalized text, assert it disappears immediately, rebuild from unchanged raw messages three times and assert it never returns. Delete one of the two supporting conversations, rebuild, and assert the now-single-conversation expression is removed.

Proposed API:

```objc
- (BOOL)deleteExpressionText:(NSString *)normalizedText error:(NSError **)error;
```

**Step 2: Verify red**

Run: `make expression-library-test data-core-test`
Expected: deletion/tombstone assertions fail.

**Step 3: Implement the transactional tombstone**

Compute the same keyed digest, insert the encrypted tombstone and delete the active expression in one transaction. Expression replacement must check tombstones before insertion. Do not add a management window in this task.

**Step 4: Verify green**

Run: `make expression-library-test data-core-test`
Expected: deletion and source-cascade tests pass with no revival.

**Step 5: Commit**

```bash
git add Sources/CodexDataCore Tests
git commit -m "feat: prevent deleted expressions from returning"
```

### Task 6: Add the immutable in-memory prefix index

**Files:**
- Create: `Sources/ExpressionLibraryCore/ExpressionSuggestionIndex.h`
- Create: `Sources/ExpressionLibraryCore/ExpressionSuggestionIndex.m`
- Create: `Tests/ExpressionLibraryCoreTests/ExpressionSuggestionIndexTests.m`

**Step 1: Write failing query tests**

Test Chinese two-character and ASCII three-character minimums, cursor-before-text extraction, selected-text suppression, exact prefix matching, suffix-only insertion, frequency/recency tie-breaking, punctuation boundaries, no-match behavior and immutable index replacement.

Proposed API:

```objc
@interface CPAExpressionSuggestion : NSObject
@property(nonatomic, copy, readonly) NSString *fullText;
@property(nonatomic, copy, readonly) NSString *insertionText;
@end


- (nullable CPAExpressionSuggestion *)suggestionForInput:(NSString *)input
    cursorLocation:(NSUInteger)cursorLocation
    selectedLength:(NSUInteger)selectedLength;
```

**Step 2: Verify red**

Run: `make expression-library-test`
Expected: compile failure because the index is missing.

**Step 3: Implement the minimal sorted in-memory index**

Keep an immutable array sorted by rank and group candidates by the first normalized character in memory. Query only that group, filter with `hasPrefix:`, and return the first suffix. Do not persist the grouping structure.

**Step 4: Verify green**

Run: `make expression-library-test`
Expected: `PASS: ExpressionSuggestionIndexTests`.

**Step 5: Commit**

```bash
git add Sources/ExpressionLibraryCore Tests/ExpressionLibraryCoreTests
git commit -m "feat: query encrypted expressions from memory"
```

### Task 7: Rebuild after data scans and publish count-only status

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/DataFoundationController.h`
- Modify: `Sources/CodexPromptAssistantPOC/DataFoundationController.m:242-340`
- Modify: `Tests/CodexPromptAssistantPOCTests/DataFoundationControllerTests.m`
- Modify: `Makefile`

**Step 1: Write failing controller tests**

After a successful synthetic scan, assert an expression rebuild occurs, snapshot diagnostics show expression/build counts only, and `suggestionForInput` returns a local suffix. On partial source failure or injected build failure, assert the previous immutable index remains available and diagnostics contain no fixture text.

**Step 2: Verify red**

Run: `make test`
Expected: controller expression status and suggestion APIs are missing.

**Step 3: Integrate on the existing serial worker queue**

Run the builder only after all source imports succeed and before closing the store. Load active expressions, build a new immutable index, then publish it under synchronization. Add `storedExpressionCount`, `expressionBuildStatus` and build duration to count-only diagnostics.

**Step 4: Verify green**

Run: `make test data-core-test expression-library-test`
Expected: every suite passes and no diagnostic contains source text or paths.

**Step 5: Commit**

```bash
git add Sources/CodexPromptAssistantPOC Tests/CodexPromptAssistantPOCTests Makefile
git commit -m "feat: rebuild expressions after local scans"
```

### Task 8: Replace the automatic fixed suggestion with local completion

**Files:**
- Modify: `Sources/CodexPromptAssistantPOC/AccessibilitySnapshot.h`
- Modify: `Sources/CodexPromptAssistantPOC/AccessibilityService.m`
- Modify: `Sources/CodexPromptAssistantPOC/main.m:240-382`
- Modify: `Tests/CodexPromptAssistantPOCTests/AccessibilitySnapshotTests.m`
- Create: `Sources/CodexPromptAssistantPOC/LocalSuggestionCoordinator.h`
- Create: `Sources/CodexPromptAssistantPOC/LocalSuggestionCoordinator.m`
- Create: `Tests/CodexPromptAssistantPOCTests/LocalSuggestionCoordinatorTests.m`

**Step 1: Write failing integration tests**

Keep focused input text transiently in the snapshot but assert `summary`, diagnostics and signatures expose only lengths/ranges. Test that automatic suggestion asks the data controller for a suffix, the overlay receives that suffix, Tab inserts the stored suffix once, Esc inserts nothing, and no match leaves the overlay hidden. Preserve all existing IME pass-through behavior.

**Step 2: Verify red**

Run: `make test`
Expected: transient text/coordinator APIs are missing.

**Step 3: Implement the local suggestion coordinator**

Remove `CPATestSuggestion` from the automatic path. Store the currently displayed insertion suffix separately, discard it whenever input signature changes, and post exactly that suffix on Tab. Keep the manual “显示测试灰字” action as an explicit diagnostics-only fixture, never as an automatic fallback.

**Step 4: Verify green and build the app**

Run: `make test app`
Expected: all tests pass; app signs and verifies; automatic no-match path shows nothing.

**Step 5: Commit**

```bash
git add Sources/CodexPromptAssistantPOC Tests/CodexPromptAssistantPOCTests
git commit -m "feat: show real local phrase completions"
```

### Task 9: Run the Phase 2 MVP checkpoint

**Files:**
- Create: `Tests/Phase2CheckpointTests/Phase2ExpressionPerformanceTests.m`
- Modify: `Makefile`
- Modify: `HANDOFF.md`
- Modify: `REFLECTION.md`
- Create: `docs/security/2026-08-20-phase2-expression-library-audit.md`

**Step 1: Add the scale and privacy probe**

Generate 100,000 synthetic user messages across two conversations to produce up to 50,000 repeated expressions. Measure rebuild time, active-index load time, 1,000 deterministic prefix queries, memory delta if available, deletion/rebuild behavior and database artifact plaintext matches.

**Step 2: Run under an enforced network-deny sandbox**

Run: `make phase2-checkpoint-test`
Expected: `phase2_checkpoint_complete=true`, rebuild `<30s`, query p95 `<10ms`, plaintext leaks `0`, duplicate expressions `0`, deleted-expression revival `0`.

**Step 3: Run full regression and analysis**

Run:

```bash
make test data-core-test expression-library-test app
clang -fobjc-arc -fmodules -Wall -Wextra -Werror --analyze \
  Sources/CodexDataCore/*.m Sources/ExpressionLibraryCore/*.m \
  Sources/CodexPromptAssistantPOC/*.m
```

Expected: all tests print `PASS`; analyzer emits no diagnostics; plist and code signature validate.

**Step 4: Re-check privacy and network boundaries**

Verify no user endpoint or Key exists in source/docs, app has no CFNetwork/Network dependency, undefined symbols contain no socket/connect/send/recv/getaddrinfo, and diagnostics contain only counts and timings.

**Step 5: Update handoff and commit**

Record what was actually verified, keep real-history import and menu visual validation explicitly pending, then commit:

```bash
git add Makefile Tests HANDOFF.md REFLECTION.md docs/security
git commit -m "test: complete the simplified expression checkpoint"
```

## Stop conditions

- Do not import real Codex or ChatGPT history during implementation tests.
- Do not add network clients, endpoint settings or API keys in Phase 2.
- Do not expand into AI learning, semantic search, templates, feedback scoring or directory watching without a new reviewed plan.
- If 100,000-message rebuild exceeds 30 seconds or memory exceeds the 50MB target, measure the bottleneck before changing to incremental persistence or a disk search index.
