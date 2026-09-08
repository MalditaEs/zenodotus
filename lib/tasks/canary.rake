# Reads the MV-6 canary: how the orchestrator is doing against Hypatia on real traffic.
# See docs/MV6-CANARY.md for what the numbers mean and what they deliberately do not cover.

# Namespaced rather than bare `def`s in the rake file, which would land on Object.
module CanaryReport
  module_function

  def pct(part, whole)
    return "-" if whole.zero?

    format("%d%%", (part.to_f / whole * 100).round)
  end

  def secs(value)
    value.nil? ? "-" : format("%ds", value.round)
  end

  def percentile(values, fraction)
    return nil if values.empty?

    sorted = values.sort
    sorted[[(sorted.length * fraction).ceil - 1, 0].max]
  end

  # Time from handing the scrape over to it being resolved. From `dispatched_at` rather than
  # `created_at`, so time spent queued is not charged to either backend.
  def latency(scrape)
    return nil unless scrape.fulfilled?

    scrape.updated_at - (scrape.dispatched_at || scrape.created_at)
  end
end

namespace :canary do
  desc "Create the per-platform canary features (idempotent, enables nothing)"
  task setup: :environment do
    # Flipper warns on every check of a feature it has never seen -- which, on the scraping
    # hot path, is a log line per scrape per platform not yet dialled. Registering them all up
    # front is quieter and makes `Flipper.features` show the real set of dials.
    Scrape::ORCHESTRATOR_SCRAPE_TYPES.each do |platform|
      feature = "orchestrator_canary_#{platform}"
      Flipper.add(feature)
      puts "#{feature}: #{Flipper.enabled?(feature) ? 'on' : 'off'}"
    end
  end

  desc "Compare the orchestrator against Hypatia over the last N days (default 7)"
  task :report, [:days] => :environment do |_task, args|
    days = (args[:days] || 7).to_i
    since = days.days.ago

    scrapes = Scrape.where("scrapes.created_at >= ?", since)
                    .includes(archive_item: :screenshot)
                    .to_a

    if scrapes.empty?
      puts "No scrapes in the last #{days} days."
      next
    end

    puts "MV-6 canary — #{scrapes.count} scrapes since #{since.to_date} (#{days}d)"
    puts

    header = format(
      "%-12s %-10s %6s %6s %6s %8s %6s %7s %7s %6s %6s",
      "backend", "platform", "total", "ok", "error", "removed", "stuck", "p50", "p90", "item", "shot"
    )
    puts header
    puts "-" * header.length

    rows = scrapes.group_by { |s| [s.backend || "(legacy)", s.scrape_type] }
    rows.keys.sort.each do |key|
      backend, platform = key
      group = rows[key]

      fulfilled = group.count(&:fulfilled?)
      ok        = group.count { |s| s.fulfilled? && !s.error? && !s.removed? }
      errored   = group.count(&:error?)
      removed   = group.count { |s| s.fulfilled? && s.removed? }
      # Neither fulfilled nor errored: still in flight, or lost. ScrapeTimeoutJob converts the
      # lost ones into errors within 30 minutes of dispatch, so a stubborn count here over a
      # window much older than that means the timeout is not being armed.
      stuck     = group.count { |s| !s.fulfilled? && !s.error? }

      # Whether an archive item was built at all, and whether it got a screenshot. Field-level
      # completeness lives on a different table per platform (ArchiveItem is a delegated type)
      # and is compared by hand during phase 1 rather than automated here -- see D8.
      with_item = group.count { |s| s.archive_item.present? }
      with_shot = group.count { |s| s.archive_item&.screenshot.present? }

      latencies = group.filter_map { |s| CanaryReport.latency(s) }

      puts format(
        "%-12s %-10s %6d %6s %6s %8s %6s %7s %7s %6s %6s",
        backend, platform, group.size,
        CanaryReport.pct(ok, group.size),
        CanaryReport.pct(errored, group.size),
        CanaryReport.pct(removed, group.size),
        CanaryReport.pct(stuck, group.size),
        CanaryReport.secs(CanaryReport.percentile(latencies, 0.50)),
        CanaryReport.secs(CanaryReport.percentile(latencies, 0.90)),
        CanaryReport.pct(with_item, fulfilled),
        CanaryReport.pct(with_shot, fulfilled)
      )
    end

    puts
    puts "Manually rescued onto Hypatia: #{scrapes.count { |s| s.rescued_at.present? }}"
    puts "Note: the callback timeout is armed for orchestrator dispatches only, so its error"
    puts "column carries stuck scrapes that Hypatia's history never recorded (D6)."
  end
end
