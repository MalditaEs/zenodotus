require "test_helper"

# Where a scrape goes, and -- more importantly -- that it keeps going to the same place. If
# the decision were re-taken on a Sidekiq retry, the canary would be measuring its own routing
# rather than either backend.
class ScrapeRoutingTest < ActiveSupport::TestCase
  ORCHESTRATOR = "https://orchestrator.example.org"
  PERCENT_KEYS = ["ORCHESTRATOR_CANARY_PERCENT",
                  *Scrape::ORCHESTRATOR_SCRAPE_TYPES.map { |p| "ORCHESTRATOR_CANARY_PERCENT_#{p.upcase}" }].freeze
  ENV_KEYS = [*%w[USE_ORCHESTRATOR MITROPOULOS_URL], *PERCENT_KEYS].freeze

  def setup
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    ENV["USE_ORCHESTRATOR"] = "true"
    ENV["MITROPOULOS_URL"] = ORCHESTRATOR
    @scrape = Scrape.create!(url: "https://www.instagram.com/p/CBcqOkyDDH8/", scrape_type: :instagram)
  end

  def teardown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Unsaved but with an id: enough for `choose_backend`, and cheap enough to take thousands.
  def unsaved(type = "instagram")
    Scrape.new(id: SecureRandom.uuid, scrape_type: type)
  end

  def routed(count, type = "instagram")
    count.times.count { unsaved(type).choose_backend == "orchestrator" }
  end

  # --- The master switch -------------------------------------------------------------------

  test "stays on Hypatia when the master switch is off" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "100"
    ENV["USE_ORCHESTRATOR"] = "false"

    @scrape.assign_backend!
    assert @scrape.via_hypatia?
  end

  test "stays on Hypatia when the orchestrator has no url" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "100"
    ENV.delete("MITROPOULOS_URL")

    @scrape.assign_backend!
    assert @scrape.via_hypatia?
  end

  # --- The percentage ----------------------------------------------------------------------

  # Permitting the orchestrator is not the same as using it.
  test "routes nobody when no percentage is set" do
    assert_equal 0, routed(1000)
  end

  # Over many scrapes, because an off-by-one in the comparison would route 1% at 0 and 99% at
  # 100 -- invisible on any single scrape.
  test "routes nobody at 0 and everybody at 100" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "0"
    assert_equal 0, routed(1000)

    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "100"
    assert_equal 1000, routed(1000)
  end

  test "routes roughly the configured share" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "30"
    # 2000 draws at 30%: mean 600, standard deviation ~20, so 90 is more than four of them.
    assert_in_delta 600, routed(2000), 90
  end

  test "raising the percentage only adds scrapes, never removes one" do
    scrapes = Array.new(500) { unsaved }

    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "10"
    at_ten = scrapes.select { |s| s.choose_backend == "orchestrator" }
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "30"
    at_thirty = scrapes.select { |s| s.choose_backend == "orchestrator" }

    assert_empty at_ten - at_thirty, "a scrape in the canary at 10% fell out of it at 30%"
    assert_operator at_thirty.size, :>, at_ten.size
  end

  # --- Per-platform overrides --------------------------------------------------------------

  test "a platform's own variable wins over the global one" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "0"
    ENV["ORCHESTRATOR_CANARY_PERCENT_TWITTER"] = "100"

    assert_equal 200, routed(200, "twitter")
    assert_equal 0, routed(200, "instagram")
  end

  # So that one platform can be shut while the rest keep running.
  test "a platform's own variable wins even when it is 0" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "100"
    ENV["ORCHESTRATOR_CANARY_PERCENT_TWITTER"] = "0"

    assert_equal 0, routed(200, "twitter")
    assert_equal 200, routed(200, "instagram")
  end

  # `${VAR:-}` in docker-compose hands the container an empty string, not an absent variable.
  test "an empty platform variable falls back to the global one" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "100"
    ENV["ORCHESTRATOR_CANARY_PERCENT_TWITTER"] = ""

    assert_equal 200, routed(200, "twitter")
  end

  # A typo must fail towards Hypatia, never towards sending everything to the orchestrator.
  test "a value that is not a whole number from 0 to 100 counts as 0" do
    ["10%", "abc", "150", "-5", "12.5", "1e2"].each do |bad|
      ENV["ORCHESTRATOR_CANARY_PERCENT"] = bad
      assert_equal 0, unsaved.canary_percent, "#{bad.inspect} should count as 0"
    end
  end

  # --- Persistence -------------------------------------------------------------------------

  # The point of persisting the decision: a Sidekiq retry must not move the scrape.
  test "the decision survives a retry even if the percentage changed underneath" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "100"
    @scrape.assign_backend!
    assert @scrape.via_orchestrator?

    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "0"
    @scrape.assign_backend!
    assert @scrape.via_orchestrator?, "a retry must not re-route a scrape already in the canary"
  end

  test "dispatched_at moves on every attempt even though the backend does not" do
    ENV["ORCHESTRATOR_CANARY_PERCENT"] = "100"
    @scrape.assign_backend!
    first = @scrape.dispatched_at
    assert_not_nil first

    travel 5.minutes do
      @scrape.assign_backend!
    end
    assert @scrape.reload.dispatched_at > first
  end

  # Not covered: a scrape_type outside ORCHESTRATOR_SCRAPE_TYPES. Every type the enum allows is
  # currently in that list, so the guard has nothing to reject; it is there for whichever
  # platform gets added next.
end
