require "test_helper"

# The orchestrator path of Scrape#perform: the bearer goes on the request, and a 401 is
# retried once with a fresh token. Neither the orchestrator nor Keycloak is contacted.
class ScrapeOrchestratorTest < ActiveSupport::TestCase
  ORCHESTRATOR = "https://orchestrator.example.org"
  TOKEN_URL = "https://sso.example.org/realms/botalite/protocol/openid-connect/token"

  ENV_KEYS = %w[USE_ORCHESTRATOR MITROPOULOS_URL MITROPOULOS_TOKEN_URL MITROPOULOS_CLIENT_ID
                MITROPOULOS_CLIENT_SECRET MITROPOULOS_AUTH_KEY]

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ENV["USE_ORCHESTRATOR"] = "true"
    ENV["MITROPOULOS_URL"] = ORCHESTRATOR
    ENV["MITROPOULOS_TOKEN_URL"] = TOKEN_URL
    ENV["MITROPOULOS_CLIENT_ID"] = "zenodotus"
    ENV["MITROPOULOS_CLIENT_SECRET"] = "s3cret"
    ENV.delete("MITROPOULOS_AUTH_KEY")
    @cache = ActiveSupport::Cache::MemoryStore.new
    # USE_ORCHESTRATOR only permits the orchestrator; the canary dial decides. Turn Instagram
    # fully on so these tests exercise the orchestrator path deterministically.
    Flipper.enable(:orchestrator_canary_instagram)
    @scrape = Scrape.create!(url: "https://www.instagram.com/p/CBcqOkyDDH8/", scrape_type: :instagram)
  end

  def teardown
    Typhoeus::Expectation.clear
    Flipper.disable(:orchestrator_canary_instagram)
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def stub_keycloak
    tokens = %w[jwt-1 jwt-2 jwt-3]
    Typhoeus.stub(TOKEN_URL).and_return do
      Typhoeus::Response.new(code: 200, body: { access_token: tokens.shift, expires_in: 300 }.to_json)
    end
  end

  def ack_body
    { scrape_id: "abc", status: "queued", platform: "instagram" }.to_json
  end

  test "sends the Keycloak bearer to the orchestrator" do
    stub_keycloak
    requests = []
    Typhoeus.stub("#{ORCHESTRATOR}/scrape").and_return do |request|
      requests << request
      Typhoeus::Response.new(code: 202, body: ack_body)
    end

    result = Rails.stub(:cache, @cache) { @scrape.perform }

    assert_equal "queued", result["status"]
    assert_equal 1, requests.size
    assert_equal "Bearer jwt-1", requests.first.options[:headers]["Authorization"]
    body = JSON.parse(requests.first.options[:body])
    assert_equal @scrape.url, body["url"]
    assert_equal @scrape.id.to_s, body["callback_id"]
  end

  test "a 401 from the orchestrator is retried once with a fresh token" do
    stub_keycloak
    bearers = []
    Typhoeus.stub("#{ORCHESTRATOR}/scrape").and_return do |request|
      bearers << request.options[:headers]["Authorization"]
      code = bearers.size == 1 ? 401 : 202
      Typhoeus::Response.new(code: code, body: code == 202 ? ack_body : { detail: "token has expired" }.to_json)
    end

    result = Rails.stub(:cache, @cache) { @scrape.perform }

    assert_equal "queued", result["status"]
    assert_equal ["Bearer jwt-1", "Bearer jwt-2"], bearers
  end

  test "a persistent 401 is an error like any other server failure" do
    stub_keycloak
    Typhoeus.stub("#{ORCHESTRATOR}/scrape").and_return(
      Typhoeus::Response.new(code: 401, body: { detail: "missing bearer token" }.to_json)
    )

    assert_raises(Scrape::ExternalServerError) do
      Rails.stub(:cache, @cache) { @scrape.perform }
    end
    assert @scrape.reload.error.present?
  end

  test "no token from Keycloak marks the scrape as errored and raises" do
    Typhoeus.stub(TOKEN_URL).and_return(
      Typhoeus::Response.new(code: 401, body: { error: "unauthorized_client" }.to_json)
    )
    Typhoeus.stub("#{ORCHESTRATOR}/scrape").and_return(Typhoeus::Response.new(code: 202, body: ack_body))

    error = assert_raises(Scrape::ExternalServerError) do
      Rails.stub(:cache, @cache) { @scrape.perform }
    end
    assert_match(/no orchestrator token/, error.message)
    assert @scrape.reload.error.present?
  end
end
