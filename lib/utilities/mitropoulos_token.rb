# typed: true

# Bearer token for the orchestrator (Mitropoulos).
#
# The orchestrator only accepts JWTs issued by Keycloak. This class obtains one with the
# client-credentials grant -- our client id and secret, no person involved -- caches it
# until shortly before it expires, and hands it to Scrape#perform_via_orchestrator.
# Tokens are short-lived (5 minutes by realm default), so the cache -- memcached in
# production, shared by web and Sidekiq -- keeps the token endpoint out of the hot path.
#
# Configuration (Figaro / ENV):
#   MITROPOULOS_TOKEN_URL      the realm's token endpoint, e.g.
#                              https://sso.botalite.es/realms/botalite/protocol/openid-connect/token
#   MITROPOULOS_CLIENT_ID      our confidential client in that realm ("zenodotus")
#   MITROPOULOS_CLIENT_SECRET  its secret (Bitwarden; never in the repo)
#   MITROPOULOS_AUTH_KEY       development only: a static bearer for an orchestrator running
#                              in AUTH_DEV_TOKEN mode. Takes precedence when set.
class MitropoulosToken
  extend T::Sig

  CACHE_KEY = "mitropoulos/access_token"
  # Refresh this long before the token actually expires, so a request that leaves now does
  # not arrive with a token that died in flight.
  EXPIRY_MARGIN = 30

  class Error < StandardError; end

  # A bearer that is valid now, or nil when no orchestrator credential is configured at all.
  # Raises Error when Keycloak refuses or cannot be reached.
  sig { returns(T.nilable(String)) }
  def self.bearer
    return Figaro.env.MITROPOULOS_AUTH_KEY if Figaro.env.MITROPOULOS_AUTH_KEY.present?
    return nil unless configured?

    cached = Rails.cache.read(CACHE_KEY)
    return cached if cached.present?

    token, expires_in = request_token
    Rails.cache.write(CACHE_KEY, token, expires_in: [expires_in - EXPIRY_MARGIN, 1].max.seconds)
    token
  end

  # Forget the cached token, e.g. after the orchestrator answered 401 with it.
  sig { void }
  def self.reset!
    Rails.cache.delete(CACHE_KEY)
  end

  sig { returns(T::Boolean) }
  def self.configured?
    Figaro.env.MITROPOULOS_TOKEN_URL.present? &&
      Figaro.env.MITROPOULOS_CLIENT_ID.present? &&
      Figaro.env.MITROPOULOS_CLIENT_SECRET.present?
  end

  # One round trip to Keycloak. Returns the token and its lifetime in seconds.
  sig { returns([String, Integer]) }
  def self.request_token
    response = Typhoeus.post(
      Figaro.env.MITROPOULOS_TOKEN_URL,
      body: {
        grant_type: "client_credentials",
        client_id: Figaro.env.MITROPOULOS_CLIENT_ID,
        client_secret: Figaro.env.MITROPOULOS_CLIENT_SECRET,
      },
      headers: { "Accept" => "application/json" },
      timeout: 10,
    )
    body = JSON.parse(response.body) rescue {}
    unless response.code == 200 && body["access_token"].present?
      # response.code is 0 when the request never got an answer (DNS, timeout, TLS).
      detail = [body["error"], body["error_description"]].compact.join(": ")
      raise Error, "Keycloak token request failed (HTTP #{response.code}) #{detail}".strip
    end
    [body["access_token"], body["expires_in"].to_i]
  end
  private_class_method :request_token
end
