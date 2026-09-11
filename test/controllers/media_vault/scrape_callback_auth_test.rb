# typed: ignore

require "test_helper"

# `scrape_result_callback` is the one route here reachable by anybody on the internet: no
# session, no CSRF token. What it demands depends on where the scrape it names was sent, so
# that the canary can run without either 401ing Hypatia's callbacks or leaving the
# orchestrator's unauthenticated. These tests pin all three positions of that switch.
class MediaVault::ScrapeCallbackAuthTest < ActionDispatch::IntegrationTest
  TOKEN = "a-shared-secret"
  ENV_KEYS = %w[ZENODOTUS_CALLBACK_TOKEN ZENODOTUS_CALLBACK_REQUIRED].freeze

  setup do
    host! Figaro.env.MEDIA_VAULT_HOST
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV_KEYS.each { |k| ENV.delete(k) }
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def scrape_on(backend)
    Scrape.create!(url: "https://www.instagram.com/p/CBcqOkyDDH8/", scrape_type: :instagram, backend: backend)
  end

  def post_callback(scrape, headers: {})
    post(
      media_vault_archive_scrape_result_callback_url,
      as: :json,
      params: { scrape_id: scrape.id, scrape_result: [{ status: "removed" }] },
      headers: headers
    )
  end

  # --- No token configured: unchanged legacy behaviour, whatever the backend ---------------

  test "callback stays open when no token is configured" do
    assert_enqueued_jobs 1 do
      post_callback(scrape_on("hypatia"))
    end
    assert_response :success
  end

  test "callback stays open for an orchestrator scrape when no token is configured" do
    assert_enqueued_jobs 1 do
      post_callback(scrape_on("orchestrator"))
    end
    assert_response :success
  end

  # --- Token configured: required for the orchestrator, not for Hypatia --------------------

  # The whole point of tying this to the scrape: production is still mostly Hypatia during the
  # canary, and Hypatia has no way to send a bearer.
  test "a Hypatia scrape needs no bearer even with a token configured" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_enqueued_jobs 1 do
      post_callback(scrape_on("hypatia"))
    end
    assert_response :success
  end

  test "a scrape with no backend recorded is treated as legacy" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_enqueued_jobs 1 do
      post_callback(scrape_on(nil))
    end
    assert_response :success
  end

  test "an orchestrator scrape is rejected with no bearer" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback(scrape_on("orchestrator"))
    end
    assert_response :unauthorized
  end

  test "an orchestrator scrape is rejected with a wrong bearer" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback(scrape_on("orchestrator"), headers: { "Authorization" => "Bearer not-the-secret" })
    end
    assert_response :unauthorized
  end

  # A near miss must fail too, not just an obviously different value.
  test "an orchestrator scrape is rejected with a bearer that only shares a prefix" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback(scrape_on("orchestrator"), headers: { "Authorization" => "Bearer #{TOKEN[0..-2]}" })
    end
    assert_response :unauthorized
  end

  # The header must carry the `Bearer` scheme, not the bare token.
  test "an orchestrator scrape is rejected with an Authorization header that is not a bearer" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback(scrape_on("orchestrator"), headers: { "Authorization" => TOKEN })
    end
    assert_response :unauthorized
  end

  test "an orchestrator scrape is accepted with the configured bearer" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_enqueued_jobs 1 do
      post_callback(scrape_on("orchestrator"), headers: { "Authorization" => "Bearer #{TOKEN}" })
    end
    assert_response :success
  end

  # --- The phase 4 switch, for once Hypatia is gone ----------------------------------------

  test "ZENODOTUS_CALLBACK_REQUIRED demands a bearer for a Hypatia scrape too" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN
    ENV["ZENODOTUS_CALLBACK_REQUIRED"] = "true"

    assert_no_enqueued_jobs do
      post_callback(scrape_on("hypatia"))
    end
    assert_response :unauthorized

    assert_enqueued_jobs 1 do
      post_callback(scrape_on("hypatia"), headers: { "Authorization" => "Bearer #{TOKEN}" })
    end
    assert_response :success
  end
end
