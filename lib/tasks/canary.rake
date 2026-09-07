# Reads the MV-6 canary: how the orchestrator is doing against Hypatia on real traffic.
# See docs/MV6-CANARY.md for what the numbers mean and what they deliberately do not cover.
namespace :canary do
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
      "%-13s %-10s %6s %8s %8s %7s %7s %8s %8s %7s %7s",
      "backend", "platform", "total", "ok", "error", "removed", "stuck", "p50", "p90", "item", "shot"
    )
    puts header
    puts "-" * header.length

    rows = scrapes.group_by { |s| [s.backend || "(legacy)", s.scrape_type] }
    rows.keys.sort.each do |key|
      backend, platform = key
      group = rows[key]

      ok      = group.count { |s| s.fulfilled? && !s.error? && !s.removed? }
      errored = group.count(&:error?)
      removed = group.count { |s| s.fulfilled? && s.removed? }
      # Neither fulfilled nor errored: still in flight, or lost. ScrapeTimeoutJob turns the
      # lost ones into errors within 30 minutes of dispatch, so a persistent count here on a
      # window older than that means the timeout is not being armed.
      stuck   = group.count { |s| !s.fulfilled? && !s.error? }

      latencies = group.filter_map do |s|
        next unless s.fulfilled?

        from = s.dispatched_at || s.created_at
        s.updated_at - from
      end

      # Whether an archive item was built at all, and whether it got a screenshot. Field-level
      # completeness lives on a different table per platform (ArchiveItem is a delegated
      # type), and is compared by hand during phase 1 rather than automated here -- see D8.
      with_item = group.count { |s| s.archive_item.present? }
      with_shot = group.count { |s| s.archive_item&.screenshot.present? }
      fulfilled = group.count(&:fulfilled?)

      puts format(
        "%-13s %-10s %6d %8s %8s %7s %7s %8s %8s %7s %7s",
        backend, platform, group.size,
        pct(ok, group.size), pct(errored, group.size), pct(removed, group.size),
        pct(stuck, group.size),
        secs(percentile(latencies, 0.50)), secs(percentile(latencies, 0.90)),
        pct(with_item, fulfilled), pct(with_shot, fulfilled)
      )
    end

    puts
    rescued = scrapes.count { |s| s.rescued_at.present? }
    puts "Manually rescued onto Hypatia: #{rescued}"
    puts "Reminder: the callback timeout is armed for orchestrator dispatches only, so its"
    puts "error column carries stuck scrapes that Hypatia's history never recorded (D6)."
  end

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
end
