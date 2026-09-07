class AddRescuedAtToScrapes < ActiveRecord::Migration[7.2]
  def change
    # When someone manually put this scrape back on Hypatia because the orchestrator could
    # not archive it. The canary has no automatic fallback on purpose -- it would hide the
    # failures being measured -- so the count of these is the honest failure rate.
    add_column :scrapes, :rescued_at, :datetime
  end
end
