# typed: ignore

require "test_helper"

# `scrape_result_callback` is the one route here reachable by anybody on the internet: no
# session, no CSRF token. These tests pin the switch that closes it -- ZENODOTUS_CALLBACK_TOKEN
# -- in both positions, because leaving it unset is a supported (legacy Hypatia) configuration
# and not an accident.
class MediaVault::ScrapeCallbackAuthTest < ActionDispatch::IntegrationTest
  TOKEN = "a-shared-secret"

  setup do
    host! Figaro.env.MEDIA_VAULT_HOST
    @saved_token = ENV["ZENODOTUS_CALLBACK_TOKEN"]
    @scrape = Scrape.create!(url: "https://www.instagram.com/p/CBcqOkyDDH8/", scrape_type: :instagram)
  end

  teardown do
    @saved_token.nil? ? ENV.delete("ZENODOTUS_CALLBACK_TOKEN") : ENV["ZENODOTUS_CALLBACK_TOKEN"] = @saved_token
  end

  def post_callback(headers: {})
    post(
      media_vault_archive_scrape_result_callback_url,
      as: :json,
      params: { scrape_id: @scrape.id, scrape_result: [{ status: "removed" }] },
      headers: headers
    )
  end

  test "callback stays open when no token is configured" do
    ENV.delete("ZENODOTUS_CALLBACK_TOKEN")

    assert_enqueued_jobs 1 do
      post_callback
    end
    assert_response :success
  end

  test "callback rejects a request with no bearer once a token is configured" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback
    end
    assert_response :unauthorized
  end

  test "callback rejects a wrong bearer" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback(headers: { "Authorization" => "Bearer not-the-secret" })
    end
    assert_response :unauthorized
  end

  # A near miss must fail too, not just an obviously different value.
  test "callback rejects a bearer that only shares a prefix with the token" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback(headers: { "Authorization" => "Bearer #{TOKEN[0..-2]}" })
    end
    assert_response :unauthorized
  end

  # The header must carry the `Bearer` scheme, not the bare token.
  test "callback rejects an Authorization header that is not a bearer" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_no_enqueued_jobs do
      post_callback(headers: { "Authorization" => TOKEN })
    end
    assert_response :unauthorized
  end

  test "callback accepts the configured bearer" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    assert_enqueued_jobs 1 do
      post_callback(headers: { "Authorization" => "Bearer #{TOKEN}" })
    end
    assert_response :success
  end

  # The 401 has to come before anything reads the body, or an unauthenticated caller could
  # still probe which scrape ids exist by telling 404 from 401.
  test "an unauthenticated caller cannot tell a real scrape id from a bogus one" do
    ENV["ZENODOTUS_CALLBACK_TOKEN"] = TOKEN

    post(media_vault_archive_scrape_result_callback_url, as: :json,
         params: { scrape_id: "XXXX", scrape_result: [{}] })
    assert_response :unauthorized

    post_callback
    assert_response :unauthorized
  end
end
