# Testing

Tests are good and can catch bugs and regressions. Test-driven development is noble and lets you design an application through tests and then write the code that passes the tests.

## Running Tests

- Run all tests: `rails test`
- Run a single test file: `rails test path/to/file.rb`

Run the full test suite at least twice on a new branch: first when branching (to see the current test state) and again before opening a PR (to make sure you didn't break anything new).

## Running the suite without a local Ruby

Everything the suite talks to is mocked (Hypatia, S3, reCAPTCHA, Ollama, remote URLs), so all
it needs beyond Ruby is Postgres and Redis. With Docker and nothing else installed, this
reproduces the CI job:

```bash
docker run -d --name zeno-pg    --network host -e POSTGRES_PASSWORD=postgres postgres:16
docker run -d --name zeno-redis --network host redis:7
docker volume create zeno-bundle
docker run -d --name zeno-ruby --network host \
  -v "$PWD":/app -v zeno-bundle:/usr/local/bundle -e BUNDLE_APP_CONFIG=/usr/local/bundle \
  -w /app ruby:3.3.7 sleep infinity

docker exec zeno-ruby bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends \
  libpq-dev libyaml-dev pkg-config libglib2.0-dev libvips libvips-dev libheif-dev \
  libpoppler-glib8 shared-mime-info ffmpeg libcurl4-openssl-dev tzdata'
docker exec zeno-ruby bash -c 'cd /app && bundle install --jobs=4 --retry=3'
```

Host networking is what makes it work unchanged: `config/database.yml` points at `localhost`
unless `ON_DOCKER=yes`, and Redis defaults to `localhost:6379`, so the containers land exactly
where the app already looks. Neo4j is not needed — CI does not run it either.

Put the environment CI sets (see `.github/workflows/main.yml`) in a `test.env` file, then:

```bash
docker exec --env-file test.env zeno-ruby bash -c 'cd /app && bundle exec rails db:setup'
docker exec --env-file test.env zeno-ruby bash -c 'cd /app && bundle exec rails test'
docker exec --env-file test.env zeno-ruby bash -c 'cd /app && bundle exec rubocop'
```

`db:setup` loads `db/schema.rb` rather than replaying migrations, so this also checks that the
schema file matches what the migrations would have produced.

## Run the whole suite, not just your file

Typhoeus stubs live in one global list and the mocks install theirs once, at load. A test that
stubbed Typhoeus and then called `Typhoeus::Expectation.clear` used to wipe everyone else's,
sending every later test to the real network — while passing perfectly when run on its own.
`TyphoeusStubIsolation` in `test_helper.rb` now snapshots that list around each test, but the
general lesson stands: a green single file proves less than you think.

## Test Coverage

After running any test it'll output a file. You can look in here and see all the code that has been run during the tests. If you're writing new code anything checked in should have 100% test coverage (or give a VERY good reason it doesn't).
