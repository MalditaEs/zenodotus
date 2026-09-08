require "test_helper"

# Where a scrape goes, and -- more importantly -- that it keeps going to the same place. If
# the decision were re-taken on a Sidekiq retry, the canary would be measuring its own routing
# rather than either backend.
class ScrapeRoutingTest < ActiveSupport::TestCase
  ORCHESTRATOR = "https://orchestrator.example.org"
  ENV_KEYS = %w[USE_ORCHESTRATOR MITROPOULOS_URL].freeze
  FEATURE = :orchestrator_canary_instagram

  def setup
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["USE_ORCHESTRATOR"] = "true"
    ENV["MITROPOULOS_URL"] = ORCHESTRATOR
    @scrape = Scrape.create!(url: "https://www.instagram.com/p/CBcqOkyDDH8/", scrape_type: :instagram)
  end

  def teardown
    Flipper.disable(FEATURE)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "stays on Hypatia when the master switch is off" do
    Flipper.enable(FEATURE)
    ENV["USE_ORCHESTRATOR"] = "false"

    @scrape.assign_backend!
    assert @scrape.via_hypatia?
  end

  test "stays on Hypatia when the orchestrator has no url" do
    Flipper.enable(FEATURE)
    ENV.delete("MITROPOULOS_URL")

    @scrape.assign_backend!
    assert @scrape.via_hypatia?
  end

  # The dial defaults to nobody, so permitting the orchestrator is not the same as using it.
  test "stays on Hypatia when the platform's dial is off" do
    @scrape.assign_backend!
    assert @scrape.via_hypatia?
  end

  test "goes to the orchestrator when the platform's dial is on" do
    Flipper.enable(FEATURE)

    @scrape.assign_backend!
    assert @scrape.via_orchestrator?
  end

  # Each platform has its own feature, so turning one on must not drag the others with it.
  test "one platform's dial does not route another platform" do
    Flipper.enable(:orchestrator_canary_twitter)
    @scrape.assign_backend!
    assert @scrape.via_hypatia?
  ensure
    Flipper.disable(:orchestrator_canary_twitter)
  end

  # The point of persisting the decision: a Sidekiq retry must not move the scrape.
  test "the decision survives a retry even if the dial changed underneath" do
    Flipper.enable(FEATURE)
    @scrape.assign_backend!
    assert @scrape.via_orchestrator?

    Flipper.disable(FEATURE)
    @scrape.assign_backend!
    assert @scrape.via_orchestrator?, "a retry must not re-route a scrape already in the canary"
  end

  test "dispatched_at moves on every attempt even though the backend does not" do
    Flipper.enable(FEATURE)
    @scrape.assign_backend!
    first = @scrape.dispatched_at
    assert_not_nil first

    travel 5.minutes do
      @scrape.assign_backend!
    end
    assert @scrape.reload.dispatched_at > first
  end

  # A feature-flag outage must not take scraping down, nor send traffic somewhere unintended.
  test "falls back to Hypatia when Flipper raises" do
    Flipper.stub(:enabled?, proc { raise "flipper is down" }) do
      @scrape.assign_backend!
    end
    assert @scrape.via_hypatia?
  end

  # Not covered: a scrape_type outside ORCHESTRATOR_SCRAPE_TYPES. Every type the enum allows
  # is currently in that list, so the guard has nothing to reject; it is there for whichever
  # platform gets added next.
end
