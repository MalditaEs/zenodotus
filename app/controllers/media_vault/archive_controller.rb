# typed: strict

class MediaVault::ArchiveController < MediaVaultController
  before_action :authenticate_super_user!, only: []

  skip_before_action :authenticate_user_and_setup!, only: :scrape_result_callback
  skip_before_action :must_be_media_vault_user, only: :scrape_result_callback

  ARCHIVE_ITEMS_PER_PAGE = 16

  # It's the index, list all the archived items,
  sig { void }
  def index
    from_date = "0000-01-01"
    to_date = (Date.today + 1).to_s

    unless params[:organization_id].blank? && params[:from_date].blank? && params[:to_date].blank?
      @organization = FactCheckOrganization.find(params[:organization_id]).load_async if params[:organization_id].present?
      from_date = params[:from_date] if params[:from_date].present?
      to_date = params[:to_date] if params[:to_date].present?
    end

    # Here we need to see if we're on a personal archive page, and limit if so to the one's this person owns.
    if params[:myvault].present? && Flipper.enabled?(:adhoc, current_user)
      archive_items = current_user.archive_items
      @myvault = true
    else
      archive_items = @organization.nil? ? ArchiveItem.publically_viewable : @organization.archive_items.publically_viewable
      # @fact_check_organizations = ArchiveItem.where.associated(:media_review).extract_associated(:media_review).collect(&:media_review_author).uniq.compact.sort_by! { |fco| fco&.name&.downcase }.map { |fco| [fco.name, fco.id] }
    end

    archive_items = archive_items.where({ posted_at: from_date...to_date }).includes(:media_review, { archivable_item: [:author, :images, :videos] }).order(posted_at: :desc)

    @pagy_items, @archive_items = pagy_array( # This is just `pagy(` when we get it back to and ActiveRecord collection
      archive_items.load_async,
      page_param: :p,
      items: ARCHIVE_ITEMS_PER_PAGE
    )

    # Set these variables if we want to
    @from_date = from_date unless from_date == "0000-01-01"
    @to_date = to_date unless to_date == (Date.today + 1).to_s && from_date == "0000-01-01"

    # Yes, this is inefficient...
    # @fact_check_organizations = ArchiveItem.all.load_async.collect { |item| item.media_review&.media_review_author }.uniq.compact
    # @fact_check_organizations.sort_by! { |fco| fco.name&.downcase }
    # @fact_check_organizations = @fact_check_organizations.map { |fco| [fco.name, fco.id] }
    # TODO ##################################
    # Redirect to status page
    # Make sure to include email instructions
    ########################################

    @render_empty = true unless params[:render_empty].present? && params[:render_empty] = false

    @page_metadata = { title: "Dashboard", description: "Media Vault Dashboard" }

    respond_to do | format |
      format.html { render "index" }
    end
  end

  # A form for submitting URLs
  sig { void }
  def add
    @myvault = params[:myvault].present?
    respond_to do |format|
      # Just a heads up, note that you have to properly render `turbo_stream`
      format.turbo_stream { render turbo_stream: turbo_stream.replace("modal", partial: "media_vault/archive/add", locals: { myvault: @myvault }) }
      format.html { redirect_to media_vault_dashboard_path }
    end
  end

  # A class representing the allowed params into the `submit_url` endpoint
  class SubmitUrlParams < T::Struct
    const :url_to_archive, String
  end

  # Entry point for submitting a URL for archiving
  # Good lord this is an unweidly method, but there's a lot of angles
  #
  # @params {url_to_archive} the url to pull in
  sig { void }
  def submit_url
    # Note that this is also done in the `api_controller.rb` file, so if you make changes do it there too
    typed_params = OpenStruct.new(params)
    url = typed_params.url_to_archive
    object_model = ArchiveItem.model_for_url(url)

    # If there's no object_model then we don't have that URL
    if object_model.nil?
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.update("modal", partial: "media_vault/archive/add", locals: { error: "Unfortunately we do not currently support archiving of links from this URL", myvault: params[:myvault].present? }) }
        format.html do
          flash.now[:error] = { title: "Error Submitting Request", body: "Unfortunately we do not currently support archiving of links from this URL" }
          redirect_to media_vault_dashboard_path
        end
      end

      return
    end

    # Try to start the scrape, otherwise... error out again
    # If submitted from myvault or user checked the private checkbox, mark as private
    is_private = params[:myvault].present? || params[:private] == "1"
    begin
      object_model.create_from_url(url, current_user, private: is_private)
    rescue StandardError => e
      Honeybadger.notify(e)

      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.update("modal", partial: "media_vault/archive/add", locals: { error: "An unexpected error has been raised submitting your request. We've been notified and will be looking into it shortly.", myvault: params[:myvault].present? }) }
        format.html do
          flash.now[:error] = { title: "Error Submitting Request", body: "An unexpected error has been raised submitting your request. We've been notified and will be looking into it shortly." }
          redirect_to media_vault_dashboard_path
        end
      end

      return
    end

    # WOOOOO
    respond_to do |format|
      flash.now[:success] = { title: "Request Successfully Queued", body: "We will notify you via email when the request is done processing.<br>This may take a while depending on the size of the current queue.".html_safe }

      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "layouts/flashes/turbo_flashes", locals: { flash: flash }),
          turbo_stream.replace("modal", html: '<turbo-frame id="modal"></turbo-frame>'.html_safe), # The html is there so they can archive another right away
        ]
      end
      format.html { redirect_to media_vault_dashboard_path }
    end
  end

  # A status page for ad hoc archives
  sig { void }
  def status
    scrapes = Scrape.where(user: current_user).order(created_at: :desc)

    @pagy_items, @scrapes = pagy_array( # This is just `pagy(` when we get it back to and ActiveRecord collection
          scrapes,
          page_param: :p,
          items: ARCHIVE_ITEMS_PER_PAGE
        )
  end

  # Restart the scrape
  sig { void }
  def restart_scrape
    scrape = Scrape.find(params[:scrape_id])
    scrape.enqueue

    respond_to do |format|
      flash.now[:success] = { title: "Scrape Restarted", body: "Your scrape has been restarted and will be processed shortly." }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace("flash", partial: "layouts/flashes/turbo_flashes", locals: { flash: flash })
        ]
      end
      format.html { redirect_to media_vault_status_path }
    end
  end

  # Export entire archive of reviewed media to a JSON File
  sig { void }
  def export_archive_data
    send_data ArchiveItem.generate_json_for_export,
      type: "application/json",
      filename: "media_vault_archive.json"
  end

  # A class representing the allowed params into the `submit_url` endpoint
  class ScrapeResultCallbackParams < T::Struct
    const :scrape_id, String
    const :scrape_result, Array
  end

  # When a scrape is over the scraper will call this. What may write to a given scrape
  # depends on where that scrape was sent -- see `authorised_callback_for?`.
  sig { void }
  def scrape_result_callback
    begin
      parsed_params = JSON.parse(request.raw_post)
    rescue JSON::ParserError
      parsed_params = {}
    end

    render json: { error: "Missing scrape id" }, status: 404 and return unless parsed_params.has_key?("scrape_id")

    begin
      scrape = Scrape.find(parsed_params["scrape_id"])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Invalid scrape id" }, status: 404 and return
    end

    return unless authorised_callback_for?(scrape)

    parsed_result = parsed_params["scrape_result"]

    # There's a bug in Hypatia where it may come in as a string, which we need to parse, or an object, where we make it an array
    begin
      parsed_result = JSON.parse(parsed_result)
    rescue TypeError
      parsed_result = [parsed_result]
    end

    ScrapeCallbackJob.perform_later(scrape, parsed_result)

    render plain: "OK", status: 200
  end

private

  # Whether this callback may write to this scrape. Renders 401 and returns false if not.
  #
  # The scrape servers call from outside the session -- no user, no CSRF token -- so this is
  # the one endpoint here that anybody on the internet can reach, and what it accepts is
  # content that lands in the archive. A scrape id is a UUIDv4 and cannot be guessed, but it
  # is not a secret either: we hand it to a third-party scraper, it travels through the
  # orchestrator, and it is logged at both ends. The bearer makes holding an id insufficient
  # on its own.
  #
  # The requirement is per scrape rather than per deployment, because during the canary both
  # systems call this endpoint: most callbacks come from Hypatia, which cannot send a bearer,
  # and some from the orchestrator, which does. Demanding a token globally would 401 the
  # majority of production; demanding none would leave the orchestrator's traffic
  # unauthenticated for the whole rollout. Tying it to the scrape's own backend protects the
  # canary from its first day and closes the endpoint by itself as the rollout reaches 100%.
  #
  # ZENODOTUS_CALLBACK_TOKEN unset still means the endpoint is open, which is what legacy
  # Hypatia needs; ZENODOTUS_CALLBACK_REQUIRED=true demands the bearer for every callback
  # whatever its backend, which is the switch for once Hypatia is gone.
  #
  # The trade-off against checking in a before_action is that the 401 now comes after the
  # scrape lookup, so an unauthenticated caller can tell a real id from a bogus one by the
  # 404. Ids being UUIDv4, that oracle cannot be enumerated and is worth the exchange.
  sig { params(scrape: Scrape).returns(T::Boolean) }
  def authorised_callback_for?(scrape)
    expected = Figaro.env.ZENODOTUS_CALLBACK_TOKEN
    return true if expected.blank?
    return true unless scrape.via_orchestrator? || Figaro.env.ZENODOTUS_CALLBACK_REQUIRED == "true"

    # Strictly `Bearer <token>`, which is what the orchestrator sends. `secure_compare` hashes
    # both sides, so it is safe on values of different length and leaks no timing.
    presented = request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
    return true if presented.present? && ActiveSupport::SecurityUtils.secure_compare(presented, expected)

    logger.warn("Rejected a callback for scrape #{scrape.id} (#{scrape.backend}): missing or invalid bearer. 🔒")
    render(json: { error: "Unauthorized" }, status: :unauthorized)
    false
  end
end
