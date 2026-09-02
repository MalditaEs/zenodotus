class Scrape < ApplicationRecord
  class MediaReviewItemNotFoundError < StandardError
    extend T::Sig

    attr_reader :url

    sig { params(url: String).void }
    def initialize(url)
      @url = url
      super("Media review with url: #{url} for scrape fulfillment not found.")
    end
  end

  enum scrape_type: {
    twitter: "twitter", instagram: "instagram", facebook: "facebook", youtube: "youtube", tiktok: "tiktok"
    }, _prefix: true

  enum initiated_from: [ "site", "plugin", "media_review" ]

  has_one :archive_item, dependent: :destroy
  belongs_to :media_review, dependent: nil, optional: true
  belongs_to :user, optional: true

  after_create :send_notification

  # Enqueue the scraping callout to Hypatia into the ActiveJob queue
  # TODO: Eventually this should be the main interface to kicking it off, but for now... no
  sig { returns(ScrapeJob) }
  def enqueue
    ScrapeJob.perform_later(self)
  end

  # Kicks the scrape off synchronously (you probably want `enqueue`). The return is the
  # parsed server response ({ success: true } from Hypatia; the ack from the orchestrator).
  # By default this GETs Hypatia (legacy). When the MV-6 orchestrator
  # (Mitropoulos) is enabled via a feature flag, it POSTs JSON to the orchestrator instead.
  # Either way the response handling is identical: a 400 {code:10} means the url is
  # unsupported (mark removed, don't retry); any other non-2xx is an error we retry.
  sig { returns(Hash) }
  def perform
    response = orchestrator_enabled? ? perform_via_orchestrator : perform_via_hypatia

    if (200..299).exclude?(response.code)
      json_error_response = JSON.parse(response.body) rescue nil
      if response.code == 400 && json_error_response.is_a?(Hash) && json_error_response["code"] == 10
        logger.info("Marking: #{self.url} as removed. 🦕")
        # The url is not valid, so we should mark it as removed
        self.fulfill([{ status: "removed" }])
        # We don't raise because we don't want it to retry.
      else
        self.mark_error
        raise Scrape::ExternalServerError.new("Error: #{response.code} returned from scrape server.")
      end
    end

    JSON.parse(response.body)
  end

  # Feature flag for the MV-6 cutover. Off by default; the legacy Hypatia path runs unless
  # both USE_ORCHESTRATOR=true and MITROPOULOS_URL are set, so rollback is one env var.
  def orchestrator_enabled?
    Figaro.env.USE_ORCHESTRATOR == "true" && Figaro.env.MITROPOULOS_URL.present?
  end

  # Legacy path: GET Hypatia with nested `url[...]` params.
  def perform_via_hypatia
    params = { url: { auth_key: Figaro.env.HYPATIA_AUTH_KEY, url: self.url, callback_id: self.id } }
    Typhoeus.get(
      Figaro.env.HYPATIA_SERVER_URL,
      followlocation: true,
      params: params,
      ssl_verifypeer: false,
      ssl_verifyhost: 0
    )
  end

  # MV-6 path: POST JSON to the orchestrator. It answers 202 (queued) and later calls back
  # the same archive#scrape_result_callback endpoint, and reproduces the 400 {code:10}
  # unsupported-url contract, so the handling in `perform` is unchanged. callback_id is sent
  # as a string (the orchestrator echoes it back verbatim in the callback).
  #
  # The orchestrator requires a Keycloak bearer (see MitropoulosToken). A 401 means the
  # cached token was revoked or expired in flight: mint a fresh one and try exactly once
  # more, so a routine key rotation never costs a scrape.
  def perform_via_orchestrator
    response = post_to_orchestrator
    if response.code == 401 && MitropoulosToken.configured?
      MitropoulosToken.reset!
      response = post_to_orchestrator
    end
    response
  rescue MitropoulosToken::Error => e
    # Same treatment as any other failure to reach the scrape server: mark it and let the
    # job retry. Keycloak being down is transient; a wrong secret is not, and the message
    # says which.
    self.mark_error
    raise Scrape::ExternalServerError.new("Error: no orchestrator token: #{e.message}")
  end

  def post_to_orchestrator
    headers = { "Content-Type" => "application/json" }
    bearer = MitropoulosToken.bearer
    headers["Authorization"] = "Bearer #{bearer}" if bearer.present?
    Typhoeus.post(
      "#{Figaro.env.MITROPOULOS_URL.chomp('/')}/scrape",
      headers: headers,
      body: { url: self.url, callback_id: self.id.to_s }.to_json
    )
  end

  sig { void }
  def send_notification
    ActionCable.server.broadcast("scrapes_channel", { scrapes_count: Scrape.where(fulfilled: false, error: nil).count })
  end

  sig { void }
  def send_completion_email
    if self.user.present?
      if self.removed
        ScrapeMailer.with(url: self.url, user: self.user, scrape_id: self.id).scrape_removed_email.deliver_later
      elsif self.error
        ScrapeMailer.with(url: self.url, user: self.user, scrape_id: self.id).scrape_error_email.deliver_later
      else
        ScrapeMailer.with(url: self.url, user: self.user).scrape_complete_email.deliver_later
      end
    end
  end

  sig { params(response: Array).void }
  def fulfill(response)
    logger.info "\n*******************************"
    logger.info "Processing Fulfill Response"
    logger.info "---------------------------"
    logger.info "URL: #{self.url}"
    logger.info "Response: #{response}"
    logger.info "*******************************\n"

    removed = false
    errored = false

    if response.empty? == false && response.first.has_key?("status") # `status` isn't returned if it's successful, should consider fixing that at some point
      case response.first["status"]
      when "removed"
        logger.info "----------------------------------"
        logger.info "Post removed at #{self.url}"
        logger.info "----------------------------------"

        removed = true
      when "error"
        logger.info "----------------------------------"
        logger.info "Post Errored at #{self.url}"
        logger.info "----------------------------------"

        errored = true
      else
        logger.info "----------------------------------"
        logger.info "Post Errored at #{self.url}"
        logger.info "----------------------------------"

        errored = true # For later in case the option for `status` could be something else
      end
    end
    # debugger

    # Process everything correctly now that we know it's not removed
    media_review_item = self.media_review
    media_review_item = MediaReview.find_by(media_url: self.url,
                                            archive_item_id: nil,
                                            taken_down: nil) if media_review_item.nil?

    unless removed || errored
      archive_item = ArchiveItem.model_for_url(self.url).create_from_hash(response, self.user)
      archive_item = archive_item.empty? ? nil : archive_item.first
      archive_item&.update!(private: self.private) unless self.private.nil?
    end

    unless media_review_item.nil?
      media_review_item.update!({ taken_down: removed, archive_item_id: archive_item&.id })
    end

    self.update!({ fulfilled: true, removed: removed, archive_item: archive_item, error: errored })

    # Update any channels listening to the scrape count
    self.send_notification

    # Send the completion email or whatever if necessary
    SendScrapeEmailJob.perform_later(self)
  rescue StandardError => e
    logger.error "Error fulfilling scrape: #{e}"
    Honeybadger.notify(e, context: {
      id: self.id,
      url: self.url,
      response: response
    })
  end

  sig { void }
  def mark_error
    self.update!({ error: true })
    self.send_notification
  end

  class Scrape::ExternalServerError < StandardError; end
end
