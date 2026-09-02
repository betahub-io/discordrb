# frozen_string_literal: true

require 'discordrb'

describe Discordrb::API do
  describe '.request rate-limit retry cap' do
    # A 429 whose response is a String (so JSON.parse works) that also answers #headers
    # (as RestClient::Response, a String subclass, does).
    let(:rate_limited_error) do
      resp = +'{"retry_after":0}' # unary + so it isn't frozen and can take singleton methods
      def resp.headers
        { retry_after: '0' }
      end

      def resp.body
        self
      end
      RestClient::TooManyRequests.new.tap do |err|
        err.define_singleton_method(:response) { resp }
      end
    end

    before do
      Discordrb::API.reset_mutexes
      allow(Discordrb::API).to receive(:sync_wait) # never actually sleep in the test
    end

    it 'gives up after MAX_RATE_LIMIT_RETRIES instead of retrying a 429 forever' do
      call_count = 0
      allow(Discordrb::API).to receive(:raw_request) do
        call_count += 1
        raise rate_limited_error
      end

      expect do
        Discordrb::API.request(:test_bucket, nil, :get, 'https://example.com/test')
      end.to raise_error(RestClient::TooManyRequests)

      # one initial attempt + MAX_RATE_LIMIT_RETRIES retries, then it re-raises
      expect(call_count).to eq(Discordrb::API::MAX_RATE_LIMIT_RETRIES + 1)
    end

    it 'floors a retry_after of 0 so it never busy-waits' do
      success = +'{}'
      def success.headers
        { x_ratelimit_remaining: '5' }
      end

      calls = 0
      allow(Discordrb::API).to receive(:raw_request) do
        calls += 1
        raise rate_limited_error if calls == 1 # succeed on the retry

        success
      end

      Discordrb::API.request(:test_bucket, nil, :get, 'https://example.com/test')

      expect(Discordrb::API).to have_received(:sync_wait)
        .with(Discordrb::API::MIN_RATE_LIMIT_BACKOFF, anything)
    end
  end
end
