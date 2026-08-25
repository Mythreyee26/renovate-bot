# How This Renovate Bot Works

This project automates dependency updates end-to-end: it opens grouped merge requests (MRs) for outdated dependencies, safely tests and merges the low-risk ones itself, and emails the right humans about what still needs a manual look. It runs as a single Jenkins pipeline (`JenkinsfileRenovate`) made of 5 stages.

---

## Stage 1 — Checkout Repo

**What runs:** `checkout scm`

Jenkins checks out the repo containing this pipeline's own files (`renovate-config.js`, `renovate-reviewers.json`, `renovate-reviewer-emails.json`, `compatibility-test.sh`) so later stages can read them.

---

## Stage 2 — Run Renovate

**What runs:** the `renovate` container executes `renovate`, configured entirely by `renovate-config.js`.

This is where new MRs get created. Renovate:

1. Connects to GitLab (`RENOVATE_ENDPOINT`, `RENOVATE_TOKEN`) and scans the repos listed under `repositories`.
2. Checks each repo's manifests (`package.json`, `requirements*.txt`, `pom.xml`, `Dockerfile`) for outdated dependencies, restricted to `enabledManagers: ['npm', 'maven', 'pip_requirements', 'dockerfile']`.
3. **Groups them** using `packageRules`, built in `renovate-config.js` by the `ecosystemGroup()` helper:
   - Related packages (e.g. all LangChain packages, all React packages, all Spring Boot packages) are grouped into **one MR per update type** (patch / minor / major) instead of one MR per package.
   - Anything not in a named group falls into a **catch-all** MR per manager per update type (e.g. "npm: all other patch updates").
   - Dockerfile updates get their own branch prefix (`docker-`) and grouping, separate from app dependencies.
   - This keeps the total MR count to roughly 15 instead of one-per-package.
4. Each MR is labeled with its update type (`patch`/`minor`/`major`) plus any `extraLabels` (e.g. `ai`, `react`, `dockerfile`).
5. Reviewers are attached per MR using `reviewerRules` from `renovate-reviewers.json` (loaded into `packageRules` at the bottom of `renovate-config.js`) — e.g. Dockerfile MRs always get the Dockerfile reviewer.

Renovate does **not** run tests or update lock files itself here (`ignoreTests: true`, `updateLockFiles: false`) — that responsibility is deliberately pushed to Stage 4.

---

## Stage 3 — Install Resolver Tools

**What runs:** inside the `resolver` container (a separate pod container from `renovate`), install `curl`, `git`, `jq`, Node.js, npm, and Maven, and configure a git identity for the bot user.

This container doesn't touch GitLab — it just needs the language toolchains that Stage 4 will use to dry-run install dependencies (`pip`, `npm`, `mvn`) and validate Dockerfiles.

---

## Stage 4 — Compatibility Test & Automerge Patches

**What runs:** `compatibility-test.sh`, wrapped with a pre-clean and post-clean of `/tmp`, npm cache, and the local Maven repo (keeps the container disk usage bounded across MRs).

This is the "safety net" stage — it decides which `patch`-labeled MRs are safe to merge automatically, repo by repo (`REPOS` array in the script, kept in sync with `repositories` in `renovate-config.js`):

1. **Fetch** all open MRs labeled `patch` targeting the base branch.
2. **Filter & sort** — skip MRs already labeled `compatibility-test-success`/`compatibility-test-failed`; process the rest oldest-first, so earlier MRs land before later ones rebase on top of them.
3. **For each MR:**
   - **Rebase** the MR's branch onto the current base branch and force-push.
     - Conflict → label `compatibility-test-failed` + `rebase-conflict`, post an explanatory note, skip to the next MR.
     - Force-push failure → label `compatibility-test-failed` + `push-failed`, skip.
   - **Detect changed manifests** in the MR diff to decide which resolver(s) to run.
   - **Run the dry-run resolver(s):**
     | Changed file | Resolver |
     |---|---|
     | `requirements*.txt` | `pip install --dry-run` |
     | `package.json` | `npm install --dry-run` |
     | `pom.xml` | `mvn dependency:resolve` |
     | `Dockerfile*` | base-image tag existence check (Docker Hub) + OS/package-manager compatibility check (e.g. catches `apt-get install` left over after switching to an Alpine base) |
   - **All resolvers pass** → label `compatibility-test-success`, post a success note, and **squash-merge the MR automatically**. The base branch is now updated, so the next MR in the loop rebases on top of it.
   - **Any resolver fails** → label `compatibility-test-failed`, post the failure details as a note, leave the MR open for manual review.
4. Emits `COMPAT_RESULT` lines to stdout, which Jenkins captures into `env.COMPAT_LOG` (currently logged but not consumed further downstream).

Only `patch` MRs are ever auto-merged — `minor` and `major` MRs always require a human reviewer.

---

## Stage 5 — Send Renovate Notification Emails

**What runs:** the `sendRenovateEmails()` Groovy function defined at the bottom of `JenkinsfileRenovate`.

This turns the current state of GitLab into three kinds of emails:

1. **Gather data:**
   - Reads `repositories` back out of `renovate-config.js` (regex-parsed), and the reviewer/email maps from the two JSON files.
   - Fetches all open MRs authored by the bot user, filtered to the configured repos.
   - Resolves each repo's numeric GitLab project ID (needed for the merged-MR API calls).
   - Fetches MRs merged *since this pipeline started* whose branch is a Renovate branch and whose merger is the bot — these are the ones Stage 4 auto-merged this run.
2. **Classify each open MR:**
   - **New** (created after this pipeline started) vs. **Old** (already open before).
   - **Update type**: major / minor / patch / other (from labels, falling back to branch/title text).
   - **Dockerfile vs. repo MR** — Dockerfile MRs are routed only to Dockerfile reviewers; everything else only to that repo's assigned reviewers (never both).
3. **Send the lead email** — one summary email to the lead containing every open MR (grouped new/old, then by update type) plus a table of everything auto-merged this run.
4. **Send reviewer emails** — one email per reviewer containing only the MRs assigned to them, split into "repo" reviewers and "Dockerfile" reviewers. A reviewer missing from `renovate-reviewer-emails.json` is skipped and logged as a warning (marks the build **unstable**, not failed).
5. If there are no open or newly-merged MRs at all, a single "nothing to do" status email goes to the lead instead.

---

## Data flow between files

```
renovate-config.js  ──(repositories, grouping rules)──▶  Stage 2 (opens MRs)
renovate-reviewers.json ──(who reviews what)──▶  Stage 2 (MR reviewers) + Stage 5 (email routing)
renovate-reviewer-emails.json ──(username → email)──▶  Stage 5 (who actually gets emailed)
compatibility-test.sh ──(same REPOS, same base branch)──▶  Stage 4 (auto-merge patch MRs)
```

All four config files must stay in sync on **repo paths** and **reviewer usernames** — they're read independently by Renovate, by the shell script, and by the Groovy email code.

## Auth

`RENOVATE_TOKEN` and `GITLAB_TOKEN` are the same GitLab Personal Access Token, injected under two env var names from one Jenkins credential (`renovate-bot-pat`) — Renovate reads the former, the shell script and Groovy `curl` calls read the latter.
