# typed: false

ENV["RAILS_ENV"] ||= "test"

require "simplecov"
require "minitest/autorun"
require_relative "../config/environment"
require_relative "mocks/hypatia_mock"
require_relative "mocks/aws_s3_mock"
require_relative "mocks/recaptcha_mock"
require_relative "mocks/ollama_mock"
require_relative "mocks/remote_url_mock"

include HypatiaMock
include AwsS3Mock

# Applications are only accepted with a passing reCAPTCHA assessment.
RecaptchaMock.install!

# Archive items are categorized by Ollama on create.
OllamaMock.install!

# Searching by URL downloads the file first.
RemoteUrlMock.install!

SimpleCov.start "rails" do
  enable_coverage :branch
end

require "rails/test_help"

# Signing S3 URLs is done locally but still needs credentials, a region and a bucket,
# and no test should reach the real S3.
ENV["AWS_S3_BUCKET_NAME"] = ENV["AWS_S3_BUCKET_NAME"].presence || "test-bucket"
Aws.config.update(
  credentials: Aws::Credentials.new("test-access-key-id", "test-secret-access-key"),
  region: ENV["AWS_REGION"].presence || "eu-west-1",
  stub_responses: true,
  s3: {
    endpoint: ENV["S3_ENDPOINT"].presence || "https://storage.googleapis.com",
    force_path_style: true
  }
)

S3_MOCK_STUB = Proc.new do |url|
  AwsS3Mock.download_file_in_s3_received_from_hypatia(url)
end

# Typhoeus stubs live in one global list, and the mocks above install theirs once, at boot.
# A test that adds its own stub and then calls `Typhoeus::Expectation.clear` wipes those too,
# and every later test in the run makes real HTTP requests -- which fails far away from the
# test that caused it. Snapshot the list around each test so a stub cannot outlive, or
# outlast, the test that added it.
module TyphoeusStubIsolation
  def before_setup
    super
    @__typhoeus_stubs = Typhoeus::Expectation.all.dup
  end

  def after_teardown
    Typhoeus::Expectation.all.replace(@__typhoeus_stubs)
    super
  end
end

class ActiveSupport::TestCase
  include TyphoeusStubIsolation

  # Run tests in parallel with specified workers
  # parallelize(workers: :number_of_processors)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end

# `before_all` runs outside the per-test transaction, so anything it creates is
# committed and outlives the class. Wrapping the whole class in a transaction keeps
# the test database clean between classes and between runs.
# Rails inserts the fixtures during the first test to run and commits them — unless a
# transaction is already open on that connection, in which case they are rolled back
# with it. TransactionalBeforeAll opens exactly such a transaction, so load the
# fixtures here, before any class-level transaction can swallow them.
ActiveSupport::TestCase.new("fixture preload").tap do |warmup|
  warmup.send(:setup_fixtures)
  warmup.send(:teardown_fixtures)
end

module TransactionalBeforeAll
  def around_all
    ActiveRecord::Base.transaction do
      super
      raise ActiveRecord::Rollback
    end
  end
end

module Minitest::Assertions
  # Assert return is a Sorbet Void type
  def assert_void(obj)
    assert_equal(T::Private::Types::Void::VOID, obj)
  end
end
