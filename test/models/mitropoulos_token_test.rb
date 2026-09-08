require "test_helper"

# Keycloak is never contacted: Typhoeus' own stubbing answers the token endpoint.
class MitropoulosTokenTest < ActiveSupport::TestCase
  TOKEN_URL = "https://sso.example.org/realms/botalite/protocol/openid-connect/token"

  ENV_KEYS = %w[MITROPOULOS_TOKEN_URL MITROPOULOS_CLIENT_ID MITROPOULOS_CLIENT_SECRET MITROPOULOS_AUTH_KEY]

  def setup
    @saved_env = ENV_KEYS.to_h { |k| [k, ENV[k]] }
    ENV_KEYS.each { |k| ENV.delete(k) }
    ENV["MITROPOULOS_TOKEN_URL"] = TOKEN_URL
    ENV["MITROPOULOS_CLIENT_ID"] = "zenodotus"
    ENV["MITROPOULOS_CLIENT_SECRET"] = "s3cret"
    # The test environment uses a null cache; caching is part of what is under test here.
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def stub_keycloak(code: 200, body: { access_token: "jwt-1", expires_in: 300 })
    calls = []
    Typhoeus.stub(TOKEN_URL).and_return do |request|
      calls << request
      Typhoeus::Response.new(code: code, body: body.to_json)
    end
    calls
  end

  test "exchanges client credentials for a token" do
    calls = stub_keycloak
    Rails.stub(:cache, @cache) do
      assert_equal "jwt-1", MitropoulosToken.bearer
    end
    assert_equal 1, calls.size
    params = calls.first.options[:body]
    assert_equal "client_credentials", params[:grant_type]
    assert_equal "zenodotus", params[:client_id]
    assert_equal "s3cret", params[:client_secret]
  end

  test "caches the token until shortly before it expires" do
    calls = stub_keycloak
    Rails.stub(:cache, @cache) do
      3.times { assert_equal "jwt-1", MitropoulosToken.bearer }
    end
    assert_equal 1, calls.size, "the token endpoint must not be hit on every scrape"
  end

  test "reset! forces a fresh token" do
    calls = stub_keycloak
    Rails.stub(:cache, @cache) do
      MitropoulosToken.bearer
      MitropoulosToken.reset!
      MitropoulosToken.bearer
    end
    assert_equal 2, calls.size
  end

  test "a refused credential raises with Keycloak's reason" do
    stub_keycloak(code: 401, body: { error: "unauthorized_client", error_description: "Invalid client credentials" })
    error = assert_raises(MitropoulosToken::Error) do
      Rails.stub(:cache, @cache) { MitropoulosToken.bearer }
    end
    assert_match(/401/, error.message)
    assert_match(/unauthorized_client/, error.message)
  end

  test "an unreachable Keycloak raises rather than returning nil" do
    stub_keycloak(code: 0, body: {})
    assert_raises(MitropoulosToken::Error) do
      Rails.stub(:cache, @cache) { MitropoulosToken.bearer }
    end
  end

  test "a static dev key wins over Keycloak and never calls it" do
    calls = stub_keycloak
    ENV["MITROPOULOS_AUTH_KEY"] = "dev-token"
    Rails.stub(:cache, @cache) do
      assert_equal "dev-token", MitropoulosToken.bearer
    end
    assert_empty calls
  end

  test "nothing configured means no bearer, not an error" do
    ENV_KEYS.each { |k| ENV.delete(k) }
    assert_not MitropoulosToken.configured?
    assert_nil MitropoulosToken.bearer
  end
end
