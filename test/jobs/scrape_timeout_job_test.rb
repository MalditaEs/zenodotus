require "test_helper"

# The timeout only fires for a scrape that is genuinely lost. Marking a live one as errored
# would be worse than the hole it closes.
class ScrapeTimeoutJobTest < ActiveJob::TestCase
  def setup
    @scrape = Scrape.create!(
      url: "https://www.instagram.com/p/CBcqOkyDDH8/",
      scrape_type: :instagram,
      backend: "orchestrator",
      dispatched_at: 31.minutes.ago
    )
  end

  test "marks a scrape whose callback never arrived as errored" do
    ScrapeTimeoutJob.perform_now(@scrape)
    assert @scrape.reload.error?
  end

  test "does nothing when the callback already arrived" do
    @scrape.update!(fulfilled: true)

    ScrapeTimeoutJob.perform_now(@scrape)
    assert_not @scrape.reload.error?
  end

  test "does nothing when the dispatch already errored" do
    @scrape.update!(error: true)
    updated = @scrape.updated_at

    ScrapeTimeoutJob.perform_now(@scrape)
    assert_equal updated.to_i, @scrape.reload.updated_at.to_i
  end

  # A Sidekiq retry re-dispatches and arms a fresh timeout. This older one must not cut that
  # newer attempt short.
  test "does nothing when the scrape was re-dispatched since it was armed" do
    @scrape.update!(dispatched_at: 1.minute.ago)

    ScrapeTimeoutJob.perform_now(@scrape)
    assert_not @scrape.reload.error?
  end

  test "is armed when the orchestrator acks a dispatch" do
    ENV["USE_ORCHESTRATOR"] = "true"
    ENV["MITROPOULOS_URL"] = "https://orchestrator.example.org"
    ENV["MITROPOULOS_AUTH_KEY"] = "dev-token"
    Flipper.enable(:orchestrator_canary_instagram)
    Typhoeus.stub("https://orchestrator.example.org/scrape").and_return(
      Typhoeus::Response.new(code: 202, body: { status: "queued" }.to_json)
    )
    scrape = Scrape.create!(url: "https://www.instagram.com/p/CBcqOkyDDH8/", scrape_type: :instagram)

    assert_enqueued_with(job: ScrapeTimeoutJob) do
      scrape.perform
    end
  ensure
    Typhoeus::Expectation.clear
    Flipper.disable(:orchestrator_canary_instagram)
    %w[USE_ORCHESTRATOR MITROPOULOS_URL MITROPOULOS_AUTH_KEY].each { |k| ENV.delete(k) }
  end
end
