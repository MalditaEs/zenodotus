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

```bash
# Once, before anything: register the five dials. Flipper warns on every check of a feature
# it has never seen, which on the scraping path is a log line per scrape.
rails canary:setup
```

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

## Trying it by hand

Everything below runs against a local checkout with no orchestrator and no Antena. Bring up
the containers first (`docs/TESTING.md`), then `rails db:setup`.

### Where does a scrape go?

```ruby
# rails console, with USE_ORCHESTRATOR=true and MITROPOULOS_URL set to anything
def goes_to(type)
  s = Scrape.create!(url: "https://example.com/#{SecureRandom.hex(4)}", scrape_type: type)
  s.assign_backend!
  s.backend
end

goes_to("instagram")                                                   # => "hypatia" (dial shut)
Flipper.enable_percentage_of_actors(:orchestrator_canary_instagram, 100)
goes_to("instagram")                                                   # => "orchestrator"
goes_to("twitter")                                                     # => "hypatia" (its own dial)

# At 30%, roughly three in ten:
Flipper.enable_percentage_of_actors(:orchestrator_canary_instagram, 30)
40.times.map { goes_to("instagram") }.tally                            # => {"hypatia"=>31, "orchestrator"=>9}

# And a scrape never moves, however the dial moves under it:
s = Scrape.create!(url: "https://example.com/stable", scrape_type: :instagram)
Flipper.enable_percentage_of_actors(:orchestrator_canary_instagram, 100)
s.assign_backend!                                    # "orchestrator"
Flipper.disable(:orchestrator_canary_instagram)
s.assign_backend!                                    # still "orchestrator"
```

### Does the callback actually reject?

Start the server with `ZENODOTUS_CALLBACK_TOKEN=secreto-de-prueba`, make one scrape on each
backend, and POST to `/archive/scrape_result_callback` (note: no `/media_vault` prefix —
`scope module:` adds no path segment).

```bash
CB=http://localhost:3000/archive/scrape_result_callback
hit() { curl -s -o /dev/null -w "%{http_code}\n" -X POST "$CB" \
  -H 'Content-Type: application/json' "${@:2}" \
  -d "{\"scrape_id\":\"$1\",\"scrape_result\":[{\"status\":\"removed\"}]}"; }

hit $HYPATIA_ID                                                    # 200 — legacy path, no bearer needed
hit $ORCH_ID                                                       # 401
hit $ORCH_ID -H 'Authorization: Bearer nope'                       # 401
hit $ORCH_ID -H 'Authorization: secreto-de-prueba'                 # 401 — the scheme is required
hit $ORCH_ID -H 'Authorization: Bearer secreto-de-prueba'          # 200
hit 00000000-0000-0000-0000-000000000000 -H 'Authorization: Bearer secreto-de-prueba'  # 404
```

### Does the timeout fire?

```ruby
s = Scrape.create!(url: "https://example.com/lost", scrape_type: :instagram)
s.update_columns(backend: "orchestrator", dispatched_at: 31.minutes.ago)
s.fulfilled?, s.error?          # => false, false — invisible today

ScrapeTimeoutJob.perform_now(s)
s.reload.error?                 # => true

# It leaves alone a scrape whose callback arrived, and one re-dispatched since:
s2.update_columns(backend: "orchestrator", dispatched_at: 31.minutes.ago, fulfilled: true)
ScrapeTimeoutJob.perform_now(s2); s2.reload.error?   # => false
s3.update_columns(backend: "orchestrator", dispatched_at: 1.minute.ago)
ScrapeTimeoutJob.perform_now(s3); s3.reload.error?   # => false
```

### What does the report look like?

```
backend      platform    total     ok  error  removed  stuck     p50     p90   item   shot
------------------------------------------------------------------------------------------
hypatia      instagram      20   100%     0%       0%     0%     60s     60s     0%     0%
orchestrator instagram      10    80%    20%       0%     0%    100s    100s     0%     0%
orchestrator twitter         1     0%     0%       0%   100%       -       -      -      -

Manually rescued onto Hypatia: 2
```
