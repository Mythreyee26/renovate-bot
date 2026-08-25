# Renovate Bot

Automates dependency updates on GitLab via Jenkins: opens grouped MRs, auto-tests + auto-merges safe patches, and emails reviewers a summary.

## Files

| File | Role |
|---|---|
| `renovate-config.js` | Renovate config — repos, grouping rules (ecosystem → 1 PR per patch/minor/major), managers enabled |
| `renovate-reviewers.json` | Which reviewer(s) get assigned per repo / per manager (e.g. Dockerfile) |
| `renovate-reviewer-emails.json` | Maps reviewer usernames → email addresses, plus the lead who gets the full summary |
| `JenkinsfileRenovate` | Jenkins pipeline: runs Renovate, runs the compat test, sends emails |
| `compatibility-test.sh` | Rebases + dry-run tests each open patch MR, auto-merges if it passes |

## Pipeline flow

1. **Run Renovate** — scans configured repos, opens/updates grouped MRs (labeled `patch`/`minor`/`major`, `dockerfile` where relevant).
2. **Compatibility test & automerge** (`compatibility-test.sh`) — for each open `patch` MR, oldest first:
   - rebase onto the base branch (skip + label on conflict)
   - run the matching dry-run resolver (`pip install --dry-run`, `npm install --dry-run`, `mvn dependency:resolve`, or a Dockerfile tag/OS-compat check)
   - pass → label `compatibility-test-success`, squash-merge automatically
   - fail → label `compatibility-test-failed`, leave for manual review
3. **Send emails** — the lead gets a full dashboard (all open + auto-merged MRs); each reviewer gets only the MRs assigned to them (repo reviewers vs. Dockerfile reviewers are separate).

## Auth

`RENOVATE_TOKEN` and `GITLAB_TOKEN` are the **same** GitLab PAT (one Jenkins credential, exposed under two env var names — Renovate CLI reads one, the custom scripts read the other).

## Setup

1. Replace placeholders in all files: `gitlab.example.com`, `your-group/your-project/...`, `LEAD_USERNAME`/`REVIEWER_TWO`/`REVIEWER_THREE` and their emails.
2. Create a Jenkins credential `renovate-bot-pat` (GitLab PAT with `api` scope).
3. Point a Jenkins pipeline job at `JenkinsfileRenovate`.
