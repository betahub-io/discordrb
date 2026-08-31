# frozen_string_literal: true

require 'discordrb'

describe Discordrb::Events::ReactionAddEvent do
  let(:server) { double('server', id: 111) }
  let(:channel) { double('channel', server: server) }
  let(:bot) { double('bot') }

  let(:member_payload) do
    {
      'roles' => [],
      'joined_at' => '2026-03-24T18:51:50.932925+00:00',
      'nick' => nil,
      'premium_since' => nil,
      'user' => { 'id' => '42', 'username' => 'Reactor', 'discriminator' => '0001', 'avatar' => nil }
    }
  end

  let(:data) do
    {
      'emoji' => { 'name' => '👍', 'id' => nil },
      'user_id' => '42',
      'message_id' => '1',
      'channel_id' => '2',
      'member' => member_payload
    }
  end

  before do
    allow(bot).to receive(:channel).with(2).and_return(channel)
  end

  describe '#user' do
    it 'resolves cache-only from the embedded member payload, never fetching on the dispatch thread' do
      # #user is evaluated eagerly by ReactionEventHandler#matches?, which runs
      # synchronously on the single gateway dispatch thread. The fix keeps resolution
      # cache-only (request: false) and builds from the embedded member payload, so it must
      # NOT trigger a REST member fetch (the old code called member(id) with one argument
      # and would fail the expectation below) nor fall back to a user fetch.
      allow(bot).to receive(:ensure_user).and_return(double('user'))
      expect(server).to receive(:member).with(42, false).and_return(nil)
      expect(bot).not_to receive(:user)

      event = described_class.new(data, bot)
      expect(event.user).to be_a(Discordrb::Member)
    end

    it 'falls back to a plain user lookup when the payload has no embedded member' do
      # REACTION_REMOVE (and any add without an embedded member) carries no member object;
      # #user must still resolve — via @bot.user — rather than crash.
      data_without_member = data.reject { |k, _| k == 'member' }
      fetched = double('user')
      expect(server).to receive(:member).with(42, false).and_return(nil)
      expect(bot).to receive(:user).with(42).and_return(fetched)

      event = described_class.new(data_without_member, bot)
      expect(event.user).to eq(fetched)
    end

    it 'falls back to a plain user lookup when the embedded member lacks a user (member_from_payload guard)' do
      malformed = data.merge('member' => { 'roles' => [] }) # no 'user' key
      fetched = double('user')
      expect(server).to receive(:member).with(42, false).and_return(nil)
      expect(bot).to receive(:user).with(42).and_return(fetched)

      event = described_class.new(malformed, bot)
      expect(event.user).to eq(fetched)
    end
  end
end
