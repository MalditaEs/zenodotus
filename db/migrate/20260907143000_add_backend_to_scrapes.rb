class AddBackendToScrapes < ActiveRecord::Migration[7.2]
  def change
    # Which system this scrape was handed to. Null means it predates the canary (Hypatia).
    # A plain string rather than a PG enum like `scrape_type`: the set of values is still
    # moving, and altering a PG enum in place is painful.
    add_column :scrapes, :backend, :string

    # When we last handed it over -- not `created_at`, which includes time spent queued.
    # Both the callback timeout and the latency metric measure from here.
    add_column :scrapes, :dispatched_at, :datetime

    add_index :scrapes, :backend
    # For finding scrapes stuck waiting on a callback.
    add_index :scrapes, [:fulfilled, :error, :dispatched_at]
  end
end
