# CLAUDE.md

Project conventions and context. Read this before changing anything.

## What this is

Demo materials for a **PSConfEU 2026 talk** on SQL Server 2025's AI features
(`EXTERNAL MODEL`, `AI_GENERATE_EMBEDDINGS`, `VECTOR(n)`,
`sp_invoke_external_rest_endpoint`, `VECTOR_SEARCH`, DiskANN indexes), driven
from PowerShell via `dbatools`. Three demos live in `demo/`:

1. `01-HHEEEEEELLLLLPPPP.ps1` — find cmdlets by meaning (vector search over `Get-Help`).
2. `02-feedbacks.ps1` — Foundry chat summariser → live prompt-injection reveal.
3. `03-similar-functionality.ps1` — find similar/duplicate functions across a PowerShell corpus.



This is **demo code, not production**. Skip prod-grade error handling, retries,
rate-limit budgeting, etc. unless they make the demo more reliable.

## Folder layout

| Folder | Purpose |
|---|---|
| `setup/` | Numbered scripts to build everything from zero (00 → 15+). One paired SQL + deployer per concept. |
| `demo/` | Presenter scripts run live on stage. All PowerShell. |
| `scripts-corpus/` | Cloned third-party repos for demo 3. **Gitignored.** |
| `backups/` | `.bak` snapshots from `setup/14-backup-database.ps1`. **Gitignored.** |

## House rules

### PowerShell

- **`dbatools`** for every SQL Server interaction: `Connect-DbaInstance`,
  `Invoke-DbaQuery`, `Backup-DbaDatabase`, `Write-DbaDbTableData`,
  `New-DbaSqlParameter`. Do not reach for `Invoke-Sqlcmd`, raw `SqlCommand`,
  or `sqlcmd.exe`.
- **`PSFramework`** for all output: `Write-PSFMessage -Level Host` for
  audience-/operator-visible text, `-Level Verbose` for internal mechanics,
  `-Level Warning` for non-fatal problems. No bare `Write-Host`.
- **Splatting** for any cmdlet with more than ~2 parameters. Build a hashtable,
  splat it. Reuse via `.Clone()` when you need a variant.
- **`Get-Secret`** from `Microsoft.PowerShell.SecretManagement` — credentials
  never appear inline. Established secret names:
  - `dbapassword` — `sa` password for the dev SQL instance.
  - `beard-mvp-subscription-id` — Azure subscription id.
  - `psconfeu2026-openai-endpoint` / `-key` / `-deployment` — Foundry connection
    (populated by `setup/00-openai.ps1`).
- **PowerShell 7+** assumed.
- **`#requires -Modules dbatools, PSFramework`** at the top of every script that
  needs them.

### SQL

- SQL files use sqlcmd-style `:setvar` parameters at the top so they're runnable
  standalone in SSMS in sqlcmd mode.
- Their paired PS deployers **strip the `:setvar` block** (one regex) and
  **substitute `$(VarName)` tokens via `[string]::Replace`** — never regex
  substitution, because values may contain `$`, `[`, `]`. `Invoke-DbaQuery`
  does **not** speak sqlcmd mode; this pattern is the only way.
- **Idempotent where reasonable.** `DROP IF EXISTS` for things that should be
  recreated each run; `IF OBJECT_ID(...) IS NULL CREATE TABLE` for things that
  must preserve state across re-runs (e.g. `dbo.ScriptFunction`, because
  loading and embedding it is hours of work).
- The database name is **`pwsh-scripts-🤣`** — yes, the emoji is intentional.
  Everything must handle it (`N'...'` literals, `[...]` identifiers).
- The Foundry **`OpenAIUri`** value is the name of the
  `DATABASE SCOPED CREDENTIAL`. The name in `02-database.sql` must equal the
  reference in `06-chat-procedures.sql`. Both PS deployers use
  `($endpoint -split 'com')[0] + 'com'` to derive the same string.

### Demo presentation style

- **Don't telegraph the joke.** Audience-facing comments sound like genuine
  surprise. Reveals come at the end.
- Mark stages with `# region : Act N — <name>` so VS Code's PowerShell
  extension can step the file cell by cell.
- `Read-Host "Press Enter ..."` at act breaks for live pacing.
- `# Audience: "..."` comments are the words you'd actually say. Read them off
  the screen if the room moves faster than expected.
- `# PRESENTER NOTE:` comments are visible only to the presenter.
- **All "naughty" prompt injection is attributed to Justin Grote.**
  He's happy to be made fun of. Do **not** introduce a fictional attacker
  (Mallory, Eve, etc.) — Justin is the sole attacker in every demo.

### People

- Repo owner: **Rob Sewell** (`rob@sewells-consulting.co.uk`), co-presenting
  with **Jess Pomfret**. The folder is named `JessAndRob` for that reason.
- Demo customer / feedback names are real PSConfEU community members. Rob and
  Jess are seeded as customers. **Do not invent community members** — only use
  real handles.

### Things to ignore

The IDE linter / spell-checker emits info-level noise that is not actionable:

- Names: Weltner, Snover, Driscoll, Bielawski, Aleksandar, Przemyslaw, Pomfret,
  Klys, Helmick, Aiello, etc.
- sqlcmd keywords: `setvar`, `sqlcmd`.
- Intentional attack strings: `yarrr`, `EXFIL`, `PWNED`.
- "Incorrect syntax near ':'" on `:setvar` lines (sqlcmd directives — valid
  only in sqlcmd-mode editors).

Acknowledge once, move on; don't try to fix.

## End-to-end build from zero

```powershell
.\setup\00-openai.ps1                          # Foundry + embedding deployment
.\setup\03-deploy-database.ps1                 # DB, master key, EmbeddingModel, CmdletHelp
.\setup\05-deploy-customer-feedback-data.ps1   # Customers + Feedback (clean seed)
.\setup\07-deploy-chat-procedures.ps1          # SummariseFeedback procs
.\setup\08-clone-repos.ps1                     # Speaker + classic repos (long, network)
.\setup\10-deploy-script-function-table.ps1    # Schema for demo 3
.\setup\11-load-script-functions.ps1           # AST load (resumable)
.\setup\12-embed-script-functions.ps1          # Embed (resumable, ~30-60 min)
.\setup\13-create-vector-index.ps1             # DiskANN
.\setup\14-backup-database.ps1                 # Snapshot — git metadata in name + description
```

After that, prefer `.\setup\15-restore-database.ps1` over re-running 03–13.

## Demo run order on the day

```powershell
.\demo\01-HHEEEEEELLLLLPPPP.ps1
.\demo\02-feedbacks.ps1
.\demo\03-similar-functionality.ps1
```

Each is structured for cell-by-cell execution. The `Read-Host` pauses are the
intended pacing; comment them out only for smoke-testing.

## When working in this repo

- **Match existing patterns.** Read the neighbouring file before editing —
  splatting style, PSFramework verbs, deploy-script structure are uniform on
  purpose.
- **Prefer next-number additions** for new setup files. Renumbering existing
  files means `git mv` plus updating every path reference in the deploy scripts;
  only do it when run-order correctness demands it.
- **No fallback / error handling for impossible states.** Trust the dev box's
  configuration.
- **No alternative LLM providers.** Foundry / Azure OpenAI is fixed for the talk.
- **Demo runners are presenter-facing.** Comments support the live narrative;
  don't strip them or rewrite them as "what the code does."
- The user **iterates aggressively**. Treat any output as a draft they may
  rewrite — be ready to react to their edits in subsequent turns rather than
  re-asserting your version.
