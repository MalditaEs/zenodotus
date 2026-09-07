# MV-6 — Canary rollout to the orchestrator

How production moves from Hypatia to the Mitropoulos orchestrator (and therefore to Antena)
a slice at a time, and how we decide it worked. Builds on `STAGING.md`, which covers the
isolated staging loop; this document is about production.

Antena itself is already validated, and YouTube now works end to end through the
orchestrator. So this canary is **not** testing whether Antena can scrape. It tests the
**integration**: the orchestrator's mapping into the shapes Zenodotus expects, media landing
in the bucket, and the callback loop closing under real traffic. That distinction sets what
we measure and why we do not paper over failures.

## Decisions

**D1 — Route per scrape, and persist the decision.**
A new `scrapes.backend` column records which system a scrape was sent to, written once and
reused. Three things depend on it: Sidekiq retries must not re-roll the dice (a scrape that
went to the orchestrator on attempt 1 must not land on Hypatia on attempt 2, or the numbers
mean nothing); the callback needs to know which system is answering; and the whole point of a
canary is being able to `GROUP BY` it afterwards.

**D2 — Flipper for the dial, not an env var.**
Flipper is already a dependency (`flipper`, `flipper-active_record`, tables in the schema)
and already in use (`Flipper.enabled?(:adhoc, current_user)`). We use
`percentage_of_actors`, never `percentage_of_time`: it hashes the actor's `flipper_id`
(`"Scrape;<uuid>"`), so the same scrape always gets the same answer, and raising the
percentage only ever *adds* scrapes. The decisive advantage over an env var is the kill
switch — `Flipper.disable` takes effect immediately, with no deploy and no restart.

**D3 — One dial per platform.**
`orchestrator_canary_twitter`, `orchestrator_canary_instagram`, and so on. At ~100 scrapes a
day, a uniform 10% split across five platforms yields ~2 scrapes per platform per day, which
answers nothing in any useful timeframe. Concentrating the same blast radius on one platform
at a time yields ~20/day for that platform. See "Why not a uniform 10%" below.

**D4 — Two levels of switch, failing towards Hypatia.**
`USE_ORCHESTRATOR` stays the master kill switch (env, needs a deploy, turns everything off);
Flipper is the fine dial. Any exception raised while consulting Flipper is reported and
routed to Hypatia. A problem in the feature-flag system must never take scraping down or send
traffic somewhere unintended.

**D5 — No automatic fallback to Hypatia.**
Re-routing a failed orchestrator scrape to Hypatia would hide exactly the signal we are
collecting: every failure silently repaired, a dashboard reading 100%, and no idea that the
integration is broken. Because Antena is already proven, the failures we expect are
*systematic* integration faults (a field the mapping drops, a video that never reaches the
bucket) — precisely the class a fallback makes invisible.

The safety net is **manual** instead: an admin action that re-enqueues a scrape explicitly on
Hypatia, which records that it happened. How many rescues you had to perform *is* the failure
rate, measured honestly.

**D6 — A per-scrape callback timeout, not a periodic reaper.**
Today a scrape whose callback never arrives sits at `fulfilled: false, error: nil`
**forever**: not fulfilled, not errored, absent from every error metric, invisible except as
a number on the admin page that looks like it is merely slow. The only recovery is the
"resubmit all unfulfilled" button. This is the single most likely failure mode of the
orchestrator path — it is the only one with an asynchronous hop back across the network — and
it must be closed before the canary starts, or failures are neither visible nor recoverable.

The project has no scheduler (no `sidekiq-cron`, `whenever`, or `clockwork`), so rather than
introduce one we arm a delayed `ScrapeTimeoutJob` per dispatch:
`ScrapeTimeoutJob.set(wait: 30.minutes).perform_later(scrape)`. No new dependency, no
polling, and the job fires exactly when it is needed. 30 minutes = the orchestrator's own
20-minute polling ceiling (`poll_max_minutes`) plus slack.

*Known bias, stated so nobody misreads the report:* the timeout is armed for orchestrator
scrapes only, so the orchestrator gets errors marked that Hypatia's history never had. That
biases the comparison **against** the orchestrator, which is the correct direction to be
wrong for a safety decision. Hypatia's own stuck rate can be recovered from history
(`fulfilled: false, error: nil` with a null backend) if we want the like-for-like number.

**D7 — Callback authentication becomes per-scrape.**
The bearer check merged as part of the orchestrator work is all-or-nothing per deployment,
which is incompatible with a canary: during the rollout most callbacks come from Hypatia with
no bearer and some from the orchestrator with one. Setting `ZENODOTUS_CALLBACK_TOKEN` today
would 401 the majority of production; leaving it unset abandons the protection for the whole
rollout.

So the requirement moves onto the scrape: a callback for a scrape routed to the orchestrator
must carry a valid bearer; one for a Hypatia scrape keeps the legacy open path. Traffic is
protected from the first day of the canary, and when the rollout reaches 100% the endpoint is
closed with no further change.

*Trade-off:* the 401 can no longer be raised before the body is parsed, so an unauthenticated
caller can once again distinguish a real scrape id from a bogus one. Scrape ids are UUIDv4
and cannot be enumerated, so this oracle is weak and worth the exchange.
`ZENODOTUS_CALLBACK_REQUIRED=true` forces the bearer for *every* callback regardless of
backend — the phase 4 switch, once Hypatia is gone.

**D8 — Measure outcomes and latency now; compare content by hand.**
`ArchiveItem` is a delegated type, so field-level completeness (screenshot, video, author,
text) lives on a different table per platform and automating it is a project of its own. It
is also unnecessary: field-level faults are systematic and show up in the first handful of
scrapes, which is what the phase 1 manual review is for. Automated reporting covers outcome
rates, latency, and whether an archive item and screenshot exist at all.

## Why not a uniform 10%

At ~100 scrapes/day over five platforms:

| Configuration | Exposure | Per platform | Time to a ±3pp answer |
|---|---|---|---|
| 10% across all five | ~10/day | ~2/day | ~100 days |
| 100% of one platform | ~20/day | ~20/day | ~10 days |

Estimating a ~95% success rate to ±3 percentage points needs roughly 200 observations. The
two rows carry nearly the same risk and differ tenfold in what they teach.

The 90/10 split is also the wrong instinct here: equal allocation matters when you must
measure both arms at once, but **Hypatia's baseline is already in the database** from years
of production. Every scrape sent to Hypatia during the canary teaches us nothing new, so the
percentage should be set by how much breakage we can absorb, not by statistics.

## Phases

### Phase 0 — Close the hole (blocking)
`ScrapeTimeoutJob`, armed on dispatch to the orchestrator. Nothing else starts until stuck
scrapes become visible.

### Phase 1 — Smoke, 2–3 days, 10% across all platforms
Here 10% is right, because this is not statistics: it is **reading all ~30 scrapes by hand**
and comparing each archived item against what Hypatia produces for the same URL. Systematic
faults appear in the first one, not the two-hundredth. Go/no-go is qualitative.

### Phase 2 — One platform at 100%, ~10 days
Start with the highest-volume platform: it answers fastest, and it is where a regression
costs most, so it is where we want to know soonest. ~200 scrapes gives that platform's rate
to ±3pp and a real decision.

### Phase 3 — The rest, ~2 weeks
Once one platform has validated the shared machinery (callback, auth, media transfer, the
mapping framework), the others only carry their own mapping. They can go on together.

### Phase 4 — Cutover
`ZENODOTUS_CALLBACK_REQUIRED=true`, Hypatia retired, the `backend` column kept for history.

Roughly a month end to end. Strictly sequential platform-by-platform would be two and a half
and is not worth it.

## Implementation

Six commits on `dfernandez/mv-6-orchestrator-cutover`.

**1 — Migration.** `scrapes.backend` (string, nullable; null = legacy, pre-canary) and
`scrapes.dispatched_at`. A plain string with a Rails enum rather than a PG enum like
`scrape_type`: values may yet change, and altering a PG enum in place is painful. Indexes on
`backend` and on `(fulfilled, error, dispatched_at)` for the stuck-scrape query.

`dispatched_at` is when we last handed the scrape over — not `created_at`, which includes
queue time. The timeout and the latency metric both need it.

**2 — Routing.** `Scrape#orchestrator_enabled?` becomes `assign_backend!` + `choose_backend`,
consulting `USE_ORCHESTRATOR`, the platform allow-list, and
`Flipper.enabled?(:"orchestrator_canary_#{scrape_type}", self)`, rescuing to `hypatia`.
`backend` is written once; `dispatched_at` on every attempt.

**3 — `ScrapeTimeoutJob`.** Armed at the end of a successful orchestrator dispatch. On firing:
no-op if the scrape is fulfilled or already errored, no-op if it was re-dispatched since
(compare `dispatched_at`), otherwise `mark_error` and notify Honeybadger.

**4 — Per-scrape callback auth.** The `before_action` becomes a check inside the action, after
the scrape is found, plus the `ZENODOTUS_CALLBACK_REQUIRED` override. Revises the behaviour
introduced earlier in this branch.

**5 — Reporting and visibility.** `rails canary:report[days]` — per backend × platform:
totals, fulfilled/error/removed/stuck, p50 and p90 latency, and the share of fulfilled scrapes
with an archive item and a screenshot. Plus `backend` shown in the admin scrapes list and in
Honeybadger context, and a "Rescue onto Hypatia" action (D5's manual net) that stamps a new
`scrapes.rescued_at` — the report counts those, and that count is the honest failure rate.
The existing "resubmit all" button keeps each scrape on its own backend now, so its comment
claiming it resubmits to Hypatia has been corrected rather than left to become untrue.

Note the project has Blazer installed, so once the column exists the same comparison can be
kept as a saved SQL dashboard for the team; the rake task is the self-contained version that
travels with the code.

**6 — This document.**

### Tests
Routing: stable across retries; honours the master switch, the platform list and the Flipper
percentage; falls back to Hypatia when Flipper raises. Timeout: no-op when fulfilled, no-op
when re-dispatched, marks error otherwise. Callback auth: Hypatia scrape with no bearer
accepted; orchestrator scrape rejected without one and accepted with it;
`ZENODOTUS_CALLBACK_REQUIRED` forcing it for both. Report task: smoke.

## Runbook

```ruby
# Phase 1 — 10% everywhere
%w[twitter instagram facebook tiktok youtube].each do |p|
  Flipper.enable_percentage_of_actors(:"orchestrator_canary_#{p}", 10)
end

# Phase 2 — one platform, all of it
Flipper.enable_percentage_of_actors(:orchestrator_canary_twitter, 100)
%w[instagram facebook tiktok youtube].each do |p|
  Flipper.disable(:"orchestrator_canary_#{p}")
end

# Stop everything, immediately, no deploy
%w[twitter instagram facebook tiktok youtube].each do |p|
  Flipper.disable(:"orchestrator_canary_#{p}")
end
```

Before phase 1, and in this order: set `ZENODOTUS_CALLBACK_TOKEN` on the orchestrator's
Secret **first**, then on Zenodotus (see `STAGING.md`) — the reverse order 401s every
orchestrator callback until the second half lands. `USE_ORCHESTRATOR=true` and
`MITROPOULOS_URL` must both be set, or every dial is inert.

Read the numbers with `rails canary:report[7]`.
