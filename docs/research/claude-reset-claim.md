# Claude Reset Claims

Checked September 23, 2026 against upstream OpenUsage main (`4ce7887`) and installed
Claude Code 2.1.281. Upstream commit `0018945` displays reset availability but does not redeem it.
The personal build adds explicit redemption based on the installed first-party client's protocol.
No live reset was redeemed during implementation or tests.

- Read grants: `GET /api/oauth/usage?cedar_ember=1`, OAuth bearer, Claude Code user agent.
- Verify identity: `GET /api/oauth/profile`, account and organization UUIDs.
- Redeem: `POST /api/organizations/{organizationUUID}/reset_rate_limits`.
- JSON: `program: cedar_ember`, exact `grant_id`, stable `request_id`.
- Results: `reset`, `already_used`, `not_limited`, `cooldown`, `ineligible`, `unavailable`.
- Unknown results, transport/HTTP errors, `stamp_indeterminate`, or `reset_unconfirmed`
  retain the pending request. No automatic retry is performed.

Each provider uses only the credentials from its latest successful live card read, checked against
its current credential generation. Work's existing prohibition on personal/Desktop credential fallback
remains intact. Selection captures account, organization, API origin, grant, limits, and expiration;
confirmation checks them again. Missing eligibility or unknown affected limits disables redemption.

A request is persisted before sending, with no token or password. An unresolved request blocks
other grants until its explicit same-ID retry returns a definitive result. A malformed persisted
request disables redemption and directs the user to Claude Usage settings.

Mock tests cover read-only opening/cancellation, request shape, duplicate confirmation, identity
changes, grant changes, eligibility, cooldown, uncertain responses, restart/retry, and account separation.

Anthropic's user-facing explanation: https://support.claude.com/en/articles/17007452-what-is-a-limit-reset
