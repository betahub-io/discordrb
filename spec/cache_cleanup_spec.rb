# frozen_string_literal: true

require 'discordrb'

describe 'Cache cleanup and access time tracking' do
  let(:bot) { Discordrb::Bot.new(token: 'fake_token') }

  describe Discordrb::Bot do
    describe '#cleanup_stale_users' do
      before do
        # Set up test users with different access times
        @old_user = double('old_user', id: 1)
        @new_user = double('new_user', id: 2)
        @recent_user = double('recent_user', id: 3)

        current_time = Time.now.to_i

        bot.instance_variable_set(:@users, {
          1 => @old_user,
          2 => @new_user,
          3 => @recent_user
        })

        bot.instance_variable_set(:@user_access_times, {
          1 => current_time - 7200,  # 2 hours ago
          2 => current_time - 1800,  # 30 minutes ago
          3 => current_time - 300    # 5 minutes ago
        })
      end

      it 'removes users older than threshold' do
        removed = bot.cleanup_stale_users(3600) # 1 hour threshold

        expect(removed).to eq(1)
        expect(bot.instance_variable_get(:@users).keys).not_to include(1)
        expect(bot.instance_variable_get(:@users).keys).to include(2, 3)
      end

      it 'keeps all users when none are stale' do
        removed = bot.cleanup_stale_users(86400) # 24 hour threshold

        expect(removed).to eq(0)
        expect(bot.instance_variable_get(:@users).keys).to include(1, 2, 3)
      end

      it 'removes all stale users when threshold is small' do
        removed = bot.cleanup_stale_users(60) # 1 minute threshold

        expect(removed).to eq(3)
        expect(bot.instance_variable_get(:@users)).to be_empty
      end

      it 'handles empty cache gracefully' do
        bot.instance_variable_set(:@users, {})
        bot.instance_variable_set(:@user_access_times, {})

        removed = bot.cleanup_stale_users(3600)

        expect(removed).to eq(0)
      end

      it 'cleans up access times for removed users' do
        bot.cleanup_stale_users(3600)

        access_times = bot.instance_variable_get(:@user_access_times)
        expect(access_times.keys).not_to include(1)
        expect(access_times.keys).to include(2, 3)
      end
    end

    describe 'user access time tracking' do
      before do
        @test_user = double('test_user', id: 123)

        bot.instance_variable_set(:@users, { 123 => @test_user })
        bot.instance_variable_set(:@user_access_times, { 123 => 0 })
        bot.instance_variable_set(:@no_cache_read, false)
      end

      it 'updates access time on cache hit' do
        before_time = Time.now.to_i

        result = bot.user(123)

        after_time = Time.now.to_i
        access_time = bot.instance_variable_get(:@user_access_times)[123]

        expect(result).to eq(@test_user)
        expect(access_time).to be >= before_time
        expect(access_time).to be <= after_time
      end
    end
  end

  describe 'negative user cache' do
    before do
      bot.instance_variable_set(:@users, {})
      bot.instance_variable_set(:@user_access_times, {})
      bot.instance_variable_set(:@negative_user_cache, {})
      bot.instance_variable_set(:@no_cache_read, false)
    end

    it 'caches unknown users to avoid repeated API calls' do
      # First call: API returns UnknownUser, should be negatively cached
      allow(Discordrb::API::User).to receive(:resolve).and_raise(Discordrb::Errors::UnknownUser.new('Unknown User'))

      result1 = bot.user(999)
      expect(result1).to be_nil

      # Second call: should NOT hit the API again (negative cache hit)
      result2 = bot.user(999)
      expect(result2).to be_nil

      expect(Discordrb::API::User).to have_received(:resolve).once
    end

    it 'expires negative cache entries after TTL' do
      allow(Discordrb::API::User).to receive(:resolve).and_raise(Discordrb::Errors::UnknownUser.new('Unknown User'))

      bot.user(999)

      # Simulate TTL expiration
      bot.instance_variable_get(:@negative_user_cache)[999] = Time.now.to_i - Discordrb::Cache::NEGATIVE_USER_CACHE_TTL - 1

      bot.user(999)

      expect(Discordrb::API::User).to have_received(:resolve).twice
    end

    it 'clears negative cache when ensure_user is called' do
      # Negatively cache user 999
      bot.instance_variable_get(:@negative_user_cache)[999] = Time.now.to_i

      # Simulate user joining (ensure_user called from GUILD_MEMBER_ADD)
      user_data = { 'id' => '999', 'username' => 'test_user', 'discriminator' => '0', 'avatar' => nil }
      bot.ensure_user(user_data)

      negative_cache = bot.instance_variable_get(:@negative_user_cache)
      expect(negative_cache).not_to have_key(999)

      users = bot.instance_variable_get(:@users)
      expect(users).to have_key(999)
    end

    it 'returns real user when resolved successfully even if negatively cached' do
      # Negatively cache user 888
      bot.instance_variable_get(:@negative_user_cache)[888] = Time.now.to_i - Discordrb::Cache::NEGATIVE_USER_CACHE_TTL - 1

      user_response = { 'id' => '888', 'username' => 'real_user', 'discriminator' => '0', 'avatar' => nil }.to_json
      allow(Discordrb::API::User).to receive(:resolve).and_return(user_response)

      result = bot.user(888)

      expect(result).to be_a(Discordrb::User)
      expect(result.username).to eq('real_user')

      # Negative cache should be cleared
      negative_cache = bot.instance_variable_get(:@negative_user_cache)
      expect(negative_cache).not_to have_key(888)
    end

    it 'cleans up expired negative cache entries during stale user cleanup' do
      now = Time.now.to_i
      bot.instance_variable_set(:@negative_user_cache, {
        100 => now - Discordrb::Cache::NEGATIVE_USER_CACHE_TTL - 60, # expired
        200 => now - 10 # still fresh
      })

      bot.cleanup_stale_users(86400) # large threshold so no positive users removed

      negative_cache = bot.instance_variable_get(:@negative_user_cache)
      expect(negative_cache).not_to have_key(100)
      expect(negative_cache).to have_key(200)
    end

    it 'does not negatively cache when another thread resolved the user concurrently' do
      # Set up: first resolve raises UnknownUser, but by the time we check,
      # another thread has populated the positive cache
      test_user = double('test_user', id: 999)
      call_count = 0

      allow(Discordrb::API::User).to receive(:resolve) do
        call_count += 1
        # Simulate another thread caching the user between API call and negative cache write
        if call_count == 1
          bot.instance_variable_get(:@users)[999] = test_user
          bot.instance_variable_get(:@user_access_times)[999] = Time.now.to_i
        end
        raise Discordrb::Errors::UnknownUser.new('Unknown User')
      end

      result = bot.user(999)

      # Should return the user that was cached by the "other thread"
      expect(result).to eq(test_user)

      # Should NOT have negatively cached since the user was found
      negative_cache = bot.instance_variable_get(:@negative_user_cache)
      expect(negative_cache).not_to have_key(999)
    end
  end

  describe Discordrb::Server do
    fixture :server_data, %i[emoji emoji_server]

    let(:server) { Discordrb::Server.new(server_data, bot) }

    describe '#cleanup_stale_members' do
      before do
        @old_member = double('old_member', id: 1)
        @new_member = double('new_member', id: 2)
        @recent_member = double('recent_member', id: 3)

        current_time = Time.now.to_i

        server.instance_variable_set(:@members, {
          1 => @old_member,
          2 => @new_member,
          3 => @recent_member
        })

        server.instance_variable_set(:@member_access_times, {
          1 => current_time - 7200,  # 2 hours ago
          2 => current_time - 1800,  # 30 minutes ago
          3 => current_time - 300    # 5 minutes ago
        })
      end

      it 'removes members older than threshold' do
        removed = server.cleanup_stale_members(3600) # 1 hour threshold

        expect(removed).to eq(1)
        expect(server.instance_variable_get(:@members).keys).not_to include(1)
        expect(server.instance_variable_get(:@members).keys).to include(2, 3)
      end

      it 'keeps all members when none are stale' do
        removed = server.cleanup_stale_members(86400) # 24 hour threshold

        expect(removed).to eq(0)
        expect(server.instance_variable_get(:@members).keys).to include(1, 2, 3)
      end

      it 'removes all stale members when threshold is small' do
        removed = server.cleanup_stale_members(60) # 1 minute threshold

        expect(removed).to eq(3)
        expect(server.instance_variable_get(:@members)).to be_empty
      end

      it 'handles empty cache gracefully' do
        server.instance_variable_set(:@members, {})
        server.instance_variable_set(:@member_access_times, {})

        removed = server.cleanup_stale_members(3600)

        expect(removed).to eq(0)
      end

      it 'cleans up access times for removed members' do
        server.cleanup_stale_members(3600)

        access_times = server.instance_variable_get(:@member_access_times)
        expect(access_times.keys).not_to include(1)
        expect(access_times.keys).to include(2, 3)
      end
    end

    describe 'member access time tracking' do
      before do
        @test_member = double('test_member', id: 456)

        server.instance_variable_set(:@members, { 456 => @test_member })
        server.instance_variable_set(:@member_access_times, { 456 => 0 })
      end

      it 'updates access time on cache hit' do
        before_time = Time.now.to_i

        result = server.member(456)

        after_time = Time.now.to_i
        access_time = server.instance_variable_get(:@member_access_times)[456]

        expect(result).to eq(@test_member)
        expect(access_time).to be >= before_time
        expect(access_time).to be <= after_time
      end
    end
  end
end
