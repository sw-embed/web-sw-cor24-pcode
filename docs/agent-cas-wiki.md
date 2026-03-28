# Wiki API Instructions for AI Agents

You have access to a shared wiki for coordinating work with other AI agents. Use the REST API below to read and write pages. Other agents may edit pages concurrently, so always use the CAS (Compare-and-Swap) protocol to avoid overwriting their changes.

## Server

```
Base URL: http://localhost:7402
```

## API Reference

### List all pages

```
GET /api/pages
→ 200 OK
["MainPage", "FeaturePlan", "ArchitectureNotes"]
```

### Read a page

```
GET /api/pages/{title}
→ 200 OK
ETag: "a1b2c3..."
Content-Type: application/json

{"title": "FeaturePlan", "content": "# Feature Plan\n...", "created_at": 1711400000, "updated_at": 1711400000}
```

Returns 404 if the page does not exist. Save the `ETag` header value — you need it for safe writes.

### Write a page (with CAS)

Always include the `If-Match` header with the ETag from your most recent read:

```
PUT /api/pages/{title}
Content-Type: application/json
If-Match: "a1b2c3..."

{"title": "FeaturePlan", "content": "# Feature Plan\n\n- Updated content"}
```

**200 OK** — Your change was saved. The response includes a new `ETag` header.

**409 Conflict** — Another agent changed the page since you read it. The response body contains:

```json
{
  "error": "conflict",
  "message": "Page was modified by another writer",
  "current_page": {"title": "...", "content": "...", "created_at": 0, "updated_at": 0},
  "current_etag": "\"new-hash...\""
}
```

On conflict: re-read the content from `current_page`, re-apply your edits to the new content, and retry the PUT with the `current_etag` value as your new `If-Match`. Use a short random delay (100-500ms) between retries. Give up after 5 attempts and move on.

### Check if a page exists

```
HEAD /api/pages/{title}
→ 200 OK (exists, ETag header included)
→ 404 Not Found
```

### Patch a page (PREFERRED for edits)

PATCH makes targeted, line-level edits instead of replacing the entire page. This prevents accidentally overwriting another agent's changes to a different section. **Use PATCH instead of PUT whenever you are editing an existing page.**

```
PATCH /api/pages/{title}
Content-Type: application/json

{
  "etag": "\"a1b2c3...\"",
  "ops": [
    {"op": "replace", "match": "| REQ-003 | REQUESTED |", "replace": "| REQ-003 | IN PROGRESS |"},
    {"op": "append_after", "match": "## Requirements", "text": "| REQ-004 | NEW |"},
    {"op": "insert_before", "match": "## Footer", "text": "## Notes"},
    {"op": "delete", "match": "- Remove this line"}
  ]
}
```

The `etag` field must contain the ETag from your most recent GET (including the quotes).

**Operations:**

| Op | Fields | What it does |
|----|--------|-------------|
| `replace` | `match`, `replace` | Find first occurrence of `match` in page, replace with `replace` |
| `append_after` | `match`, `text` | Find line containing `match`, insert `text` on the next line |
| `insert_before` | `match`, `text` | Find line containing `match`, insert `text` before that line |
| `delete` | `match` | Find and remove first occurrence of `match` |

Operations apply sequentially — each op sees the result of the previous one.

**Responses:**

**200 OK** — All ops applied, page saved. New `ETag` header in response.

**409 Conflict** — ETag mismatch (same as PUT). Response body has `current_page` and `current_etag`.

**422 Unprocessable Entity** — A `match` string was not found in the page content:

```json
{
  "error": "match_not_found",
  "message": "Op 0 match string not found in page content",
  "op_index": 0,
  "match": "| REQ-003 | REQUESTED |",
  "current_page": {"title": "...", "content": "...", ...},
  "current_etag": "\"...\""
}
```

On 422: your match target no longer exists in the page (another agent changed it). Re-read the current_page from the response, find the correct match string, and retry.

### Delete a page

```
DELETE /api/pages/{title}
→ 200 OK
```

## Workflow

1. **Read first.** GET the page to get the current content and ETag.
2. **Identify your changes.** Determine the specific lines or strings you need to modify.
3. **Use PATCH for edits.** Send targeted ops (replace, append_after, insert_before, delete) instead of rewriting the whole page.
4. **Use PUT only for new pages** or when you genuinely need to restructure the entire page.
5. **Handle errors.** On 409 (conflict) or 422 (match not found), re-read the page from the response body and retry.
6. **Verify.** After all your edits, GET the pages to confirm the final state.

## Rules for Multi-Agent Coordination

- **Use PATCH, not PUT, for edits.** PATCH makes surgical changes. PUT replaces the entire page and can silently destroy another agent's edits to a different section — even when ETags match.
- **Never skip the ETag.** Always include it in PATCH requests and If-Match on PUT requests.
- **Read before writing.** Do not edit a page you have not first read in this session.
- **Retry on conflict or match failure.** 409 and 422 are normal — they mean another agent wrote first or restructured the section. Re-read and retry.
- **Match specific strings.** Use match strings that uniquely identify the line or field you're changing. Avoid matching on generic text like "DONE" that could appear in multiple places.
- **One concern per PATCH.** Don't combine unrelated edits in a single PATCH request. If one op fails, the entire PATCH fails.
- **Use clear page names.** Use descriptive CamelCase titles (e.g., `FeatureRequirements`, `ArchitectureDecisions`, `TaskBoard`).

## Page Content Format

Pages use Markdown with wiki-link extensions:

- Standard Markdown: headings, bold, italic, lists, code blocks, links
- Wiki links: `[[PageName]]` links to another wiki page
- Display text: `[[PageName|click here]]` renders as "click here" linking to PageName
- Links to nonexistent pages appear as red links in the UI

## Example: Coordinating a Feature Plan

```
1. Agent-1 reads GET /api/pages/FeaturePlan → gets content + ETag "abc"
2. Agent-1 PATCHes to add a row:
   {"etag": "\"abc\"", "ops": [{"op": "append_after", "match": "| REQ-002 |", "text": "| REQ-003 | REQUESTED | Need auth module |"}]}
   → 200 OK, new ETag "def"

3. Agent-2 reads GET /api/pages/FeaturePlan → gets updated content + ETag "def"
4. Agent-2 PATCHes to update a status:
   {"etag": "\"def\"", "ops": [{"op": "replace", "match": "| REQ-001 | REQUESTED |", "replace": "| REQ-001 | DONE |"}]}
   → 200 OK, new ETag "ghi"

If both agents PATCH at the same time:
- One gets 200 OK
- The other gets 409 Conflict with the winner's content and ETag
- The loser re-reads from the conflict response and retries
```

## Using curl (for tool-use agents)

```bash
# List all pages
curl -s http://localhost:7402/api/pages

# Read a page (note the ETag in the response headers)
curl -si http://localhost:7402/api/pages/FeaturePlan

# PATCH: replace a specific string (preferred for edits)
curl -s -w "\nHTTP %{http_code}" \
  -X PATCH \
  -H "Content-Type: application/json" \
  -d '{"etag": "\"a1b2c3...\"", "ops": [{"op": "replace", "match": "REQUESTED", "replace": "IN PROGRESS"}]}' \
  http://localhost:7402/api/pages/FeaturePlan

# PATCH: add a line after a heading
curl -s -w "\nHTTP %{http_code}" \
  -X PATCH \
  -H "Content-Type: application/json" \
  -d '{"etag": "\"a1b2c3...\"", "ops": [{"op": "append_after", "match": "## Tasks", "text": "- [ ] New task added by agent"}]}' \
  http://localhost:7402/api/pages/FeaturePlan

# PUT: create a new page (no ETag needed for new pages)
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title":"NewPage","content":"# New Page\n\nCreated by agent."}' \
  http://localhost:7402/api/pages/NewPage

# PUT with CAS: full page replacement (use sparingly)
curl -s -w "\nHTTP %{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -H 'If-Match: "a1b2c3..."' \
  -d '{"title":"FeaturePlan","content":"# Completely rewritten content"}' \
  http://localhost:7402/api/pages/FeaturePlan
```
