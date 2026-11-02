# Shared rules: <batch>, <date>

<N> agent sessions run in parallel. Each one takes one feature from BE through to the clients, then local E2E, then
(if asked) deploy.

| Session | Feature | BE / web / mobile branch | Migration range |
|---|---|---|---|
| `<slug>` | … | `feat/<x>` | NNN–NNN |

Shared folder (persistent — not /tmp): `~/worktrees/session-prompts/<batch>/` (= `$W`).

## User instructions (quoted)

> "…"

Interpretation:
- Product decisions: decide them yourself from the brief/plan, record them in the plan and the report. What must be
  asked: <…>.
- Production approvals already given: <e.g. non-destructive migrations; deploy after E2E passes>.

## Read first
1. The project's `AGENTS.md` + `docs/blueprint/10-workflow.md`.
2. `$W/<slug>/HANDOFF.md`.

## Worktree
`~/worktrees/<repo>/feat-<slug>` from `origin/<main branch>` `<sha>`.

## Local resources (use only your own)

| Session | BE port | Redis | Typesense | Gateway stand-in | DB prefix |
|---|---|---|---|---|---|
| `<slug>` | 81x1 | 64x1 | `typesense-<slug>` 127.0.0.1:81x1 | 81x1 | `<p>_<slug>_*` |

Do not touch: <shared port/DB/container>.

## Required E2E before deploy
1. BE: `go test ./...` FAIL-set = master; a new e2e per case (fails on master); full regression master vs branch;
   migrations tested on a dump copy.
2. Web: vitest, eslint/prettier on the changed files, Playwright on the main flows (lock `vite5173`).
3. Mobile: analyze vs baseline, test vs baseline, testing against the local BE.
4. Results in `$W/<slug>/E2E.md`.

## Migrations & production commands
<migration classes + the approvals that apply to this batch>

## Deploying without collisions
`$W/bin/lock deploy acquire|release <slug> "<note>"`; order per release; DEPLOY-LOG.md.

## State & reports
PROGRESS.md (append), INTERFACES.md (append-only), E2E.md, RELEASE.md, DONE, DEPLOYED. Final report: branch, worktree,
SHA, PR, E2E, migrations, deploy, decisions, what is still open.
