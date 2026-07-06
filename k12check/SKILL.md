---
name: k12check
description: Safely verify ChatGPT/OpenAI K12 workspace account UUID availability. Use when Codex needs to check whether K12 workspace IDs are currently accessible, compare S1/S2/S3/S4 candidate lists, parse local K12-ID or K12-ACCOUNT evidence, run the lowest-risk exchange_workspace_token check, or explain why unauthenticated probing cannot prove availability. Default mode forbids invite/join, leave/delete, and credential export unless the user explicitly authorizes that higher-risk action.
---

# K12 Check

## Purpose

Verify K12 workspace IDs with the lowest practical risk. Treat "available" as: the current ChatGPT session can exchange into the target workspace ID and the returned token claims `plan_type`/`chatgpt_plan_type` as `k12`.

## Status Labels

- `offline-evidence`: local files prove a workspace was previously exported as K12, but no live check was run.
- `unauthenticated-inconclusive`: a no-login HTTP probe returned only generic auth/403 behavior and cannot distinguish good IDs from fake IDs.
- `exchange-only-available`: live exchange returned the requested account ID and K12 plan.
- `exchange-only-no-access`: live exchange did not return the requested account ID.
- `accessible-not-k12`: live exchange returned the requested account ID but the plan was not K12.
- `authenticated-required`: live proof needs a ChatGPT session for a test account.
- `explicit-join-required`: proving joinability would require `POST /backend-api/accounts/{id}/invites/request`; stop unless the user explicitly authorizes that side effect.
- `blocked-no-safe-session`: no safe browser/session is available.

## Safety Rules

- Default to exchange-only checks. Do not call `POST /backend-api/accounts/{id}/invites/request`, `DELETE /backend-api/accounts/{id}/users/{userId}`, export credentials, copy tokens, or run a bookmarklet that does those actions unless the user explicitly asks for that exact action after risk is explained.
- Do not use the user's ordinary logged-in ChatGPT account for live checks unless the user explicitly authorizes it. Prefer a throwaway/test account in an isolated browser profile.
- Remember that tabs in the same Edge InPrivate window share one temporary session. For true isolation, launch a separate Edge profile such as `msedge --inprivate --user-data-dir=<temp-dir> --remote-debugging-port=<port> https://chatgpt.com/`, record the PID/profile/port, and do not clean it up unless it is clearly created by the current session and safe to close.
- Never print access tokens, refresh tokens, session tokens, cookies, full emails, or browser storage. Only report target ID, source label, status, HTTP code, returned account prefix, plan, and short notes.
- The exchange endpoint may change the current ChatGPT workspace context in that browser session. Capture the starting account ID and restore it when possible. Report if restore failed or was not attempted.
- An unauthenticated probe is not proof. If a real ID and a fake UUID both return the same `403` or generic HTML response, report `unauthenticated-inconclusive`.

## Workflow

1. Normalize candidate IDs.
   - Accept pasted lines like `uuid | S1, S2, S3`.
   - Normalize full-width or long dash variants to `-`.
   - Deduplicate UUIDs while preserving the first source label.

2. Check local evidence first when present.
   - `K12-ID.txt` proves only that an ID was collected.
   - `K12-ACCOUNT.txt` or exported JSON with `chatgpt_account_id` and `plan_type: k12` proves prior K12 export for that account.
   - Do not output stored tokens while parsing evidence.

3. Decide whether live checking is safe.
   - If no safe authenticated session exists, stop with `authenticated-required` or `blocked-no-safe-session`.
   - If the user wants "can this account already use the space?", use exchange-only.
   - If the user wants "can an account join this unknown space?", explain that the proof requires `invites/request` and label `explicit-join-required`.

4. Run the exchange-only check.
   - Use the bundled script when a ChatGPT page is reachable through Chrome DevTools Protocol.
   - Keep `--restore-current` enabled unless the user explicitly wants to stay in the last successful workspace.
   - If using a browser plugin tab instead of CDP, follow the same logic: `GET /api/auth/session`, then for each ID `GET /api/auth/session?exchange_workspace_token=true&workspace_id=<id>&reason=setCurrentAccount`, decode only the returned JWT claims needed for `chatgpt_account_id` and plan, and redact all tokens.

5. Report results by status.
   - `exchange-only-available`: returned account ID equals target and plan is `k12`.
   - `accessible-not-k12`: returned account ID equals target but plan is not `k12`.
   - `exchange-only-no-access`: response returns another account, no target token, error, or timeout.
   - Include the method used and whether any browser context was restored.

## Script

Use `scripts/check_k12_workspaces.mjs` for deterministic exchange-only checks against an isolated Edge/Chrome CDP port:

```powershell
node C:\Users\DELL\.codex\skills\k12check\scripts\check_k12_workspaces.mjs `
  --ids-file C:\Users\DELL\Desktop\K12\K12-ID.txt `
  --cdp http://127.0.0.1:9223
```

Useful options:

- `--ids "uuid | S2"` can be repeated or contain multiple lines.
- `--ids-file <path>` reads pasted ID lists.
- `--cdp http://127.0.0.1:<port>` points at the remote-debugging browser.
- `--json` emits machine-readable sanitized output.
- `--no-restore-current` skips restoring the starting workspace.
- `--self-test` validates parser behavior without touching the network or browser.

The script intentionally has no invite/join or credential-export mode.
