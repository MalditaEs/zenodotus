# Closes the one failure mode nothing else catches: the orchestrator accepted the scrape
# (202) and the callback never arrived. Without this the scrape sits at
# `fulfilled: false, error: nil` forever -- not fulfilled, not errored, absent from every
# error metric, and indistinguishable on the admin page from one that is merely slow. It is
# the most likely way the orchestrator path fails, because it is the only one with an
# asynchronous hop back across the network.
#
# Armed per dispatch rather than swept periodically: this project has no scheduler
# (no sidekiq-cron, whenever or clockwork), and one delayed job per scrape needs no new
# dependency, does no polling, and fires exactly when it is needed. See D6 in
# docs/MV6-CANARY.md.
class ScrapeTimeoutJob < ApplicationJob
  queue_as :default

  def perform(scrape)
    # The callback beat us here, or the dispatch itself already failed and marked it.
    return if scrape.fulfilled? || scrape.error?

    # Re-dispatched since we were armed (a Sidekiq retry of ScrapeJob). A later timeout is
    # queued for that attempt and owns this scrape; giving up now would cut it short.
    return if scrape.dispatched_at.present? && scrape.dispatched_at > Scrape::CALLBACK_TIMEOUT.ago

    logger.warn("Scrape #{scrape.id} timed out waiting for a callback from #{scrape.backend}. ⏰")
    scrape.mark_error
    Honeybadger.notify(
      "Scrape timed out waiting for its callback",
      context: {
        id: scrape.id,
        url: scrape.url,
        backend: scrape.backend,
        scrape_type: scrape.scrape_type,
        dispatched_at: scrape.dispatched_at,
      }
    )
  end
end
