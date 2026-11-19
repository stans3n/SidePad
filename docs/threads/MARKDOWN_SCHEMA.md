# Thread Markdown format and recovery

SidePad stores each project in a UTF-8 Markdown file under `~/Library/Application Support/SidePad/Threads/`. The filename matches the project's UUID. Renaming a project leaves its filename intact. Live tasks and their links to projects are stored separately in `WorkspaceStore`.

## Format

```markdown
---
schema_version: 1
id: "0ce22efb-0fd2-4932-a358-cc887ac42a3d"
parent_id: null
title: "Sample project"
status: active
created_at: "2026-06-01T09:00:00.000Z"
updated_at: "2026-06-01T09:00:00.000Z"
last_activity: "2026-06-01T09:00:00.000Z"
---

# Sample project

## Current State
The first draft is ready.

## Next Action
Review the draft and record the open questions.
```

Frontmatter uses scalar YAML values. `parent_id` can reference another project's UUID or be `null`. Valid statuses are `active`, `paused`, `completed`, and `archived`. Dates use ISO 8601 with a timezone. Within an editable section, use `###` or deeper headings. SidePad preserves unrelated prose, comments, and unknown fields when saving supported edits.

Both document versions can be loaded. Saving the first checkpoint to a version 1 file upgrades it to version 2 and saves the original bytes in `.schema-backups/`. The `## Checkpoints` section stores a versioned JSON block with checkpoint IDs, timestamps, notes, snapshots, and related task and resource references. `## Progress Events` stores activity separately. Task references in these sections describe saved history.

## Editing and recovery

Use **Open Markdown** to edit project context outside SidePad, then choose **Reload**. Keep the UUID, filename, valid parent references, and structured history intact. SidePad checks the last loaded file names and bytes before saving. If they have changed, review the external edits or use **Save Local Copy** to preserve a draft as a separate project. If loaded history changes on disk, SidePad keeps the previous state in memory and can preserve the original file in `.history-recovery/` for review.

After an interrupted write, SidePad may report a `.thread-transaction-<UUID>/` directory with `manifest.json`, `before/`, and `after/`. The store pauses writes while the transaction needs recovery.

1. Quit SidePad and back up the entire Threads directory, including the pending transaction and any later edits.
2. Use `manifest.json` to identify the affected files. Compare each current file with its `before/` and `after/` copies to decide what to keep.
3. To roll back, restore the original files from `before/`. Move files created by the interrupted transaction out of the Threads directory only after checking them for later edits.
4. Check project UUIDs and parent links. Move the resolved transaction directory out of the Threads directory and reopen SidePad. Keep the backup until the library loads successfully.
