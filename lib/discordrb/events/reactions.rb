# frozen_string_literal: true

require 'discordrb/events/generic'
require 'discordrb/data'

module Discordrb::Events
  # Generic superclass for events about adding and removing reactions
  class ReactionEvent < Event
    include Respondable

    # @return [Emoji] the emoji that was reacted with.
    attr_reader :emoji

    # @!visibility private
    attr_reader :message_id

    def initialize(data, bot)
      @bot = bot

      @emoji = Discordrb::Emoji.new(data['emoji'], bot, nil)
      @user_id = data['user_id'].to_i
      @message_id = data['message_id'].to_i
      @channel_id = data['channel_id'].to_i
      # Guild reaction-add payloads embed the full member object (including its user);
      # kept so #user can resolve without a REST fetch (see #user).
      @member_data = data['member']

      super(data, bot)
    end

    # @return [User, Member] the user that reacted to this message, or member if a server exists.
    def user
      # Resolve WITHOUT a blocking REST fetch. ReactionEventHandler#matches? eagerly
      # evaluates event.user, and #matches? runs synchronously on the single gateway
      # dispatch thread — so a cache-miss REST member fetch here head-of-line-blocks every
      # following packet (INTERACTION_CREATE included) and makes interactions miss the 3s
      # deadline. Use the cache, then the embedded member payload, and only fall back to a
      # (rarer) user fetch.
      @user ||= if server
                  @server.member(@user_id, false) || member_from_payload || @bot.user(@user_id)
                else
                  @bot.user(@user_id)
                end
    end

    # @return [Message] the message that was reacted to.
    def message
      @message ||= channel.load_message(@message_id)
    end

    # @return [Channel] the channel that was reacted in.
    def channel
      @channel ||= @bot.channel(@channel_id)
    end

    # @return [Server, nil] the server that was reacted in. If reacted in a PM channel, it will be nil.
    def server
      @server ||= channel.server
    end

    private

    # Builds a Member from the embedded gateway member payload (present on guild
    # reaction-adds), avoiding a REST member fetch on the dispatch thread. Returns nil if
    # the payload is missing or malformed.
    def member_from_payload
      return nil unless @member_data && @member_data['user']

      Discordrb::Member.new(@member_data, @server, @bot)
    rescue StandardError
      nil
    end
  end

  # Generic superclass for event handlers pertaining to adding and removing reactions
  class ReactionEventHandler < EventHandler
    def matches?(event)
      # Check for the proper event type
      return false unless event.is_a? ReactionEvent

      [
        matches_all(@attributes[:emoji], event.emoji) do |a, e|
          case a
          when Integer
            e.id == a
          when String
            e.name == a || e.name == a.delete(':') || e.id == a.resolve_id
          else
            e == a
          end
        end,
        matches_all(@attributes[:message], event.message_id) do |a, e|
          a == e
        end,
        matches_all(@attributes[:in], event.channel) do |a, e|
          case a
          when String
            # Make sure to remove the "#" from channel names in case it was specified
            a.delete('#') == e.name
          when Integer
            a == e.id
          else
            a == e
          end
        end,
        matches_all(@attributes[:from], event.user) do |a, e|
          case a
          when String
            a == e.name
          when :bot
            e.current_bot?
          else
            a == e
          end
        end
      ].reduce(true, &:&)
    end
  end

  # Event raised when somebody reacts to a message
  class ReactionAddEvent < ReactionEvent; end

  # Event handler for {ReactionAddEvent}
  class ReactionAddEventHandler < ReactionEventHandler; end

  # Event raised when somebody removes a reaction to a message
  class ReactionRemoveEvent < ReactionEvent; end

  # Event handler for {ReactionRemoveEvent}
  class ReactionRemoveEventHandler < ReactionEventHandler; end

  # Event raised when somebody removes all reactions from a message
  class ReactionRemoveAllEvent < Event
    include Respondable

    # @!visibility private
    attr_reader :message_id

    def initialize(data, bot)
      @bot = bot

      @message_id = data['message_id'].to_i
      @channel_id = data['channel_id'].to_i

      super(data, bot)
    end

    # @return [Channel] the channel where the removal occurred.
    def channel
      @channel ||= @bot.channel(@channel_id)
    end

    # @return [Message] the message all reactions were removed from.
    def message
      @message ||= channel.load_message(@message_id)
    end
  end

  # Event handler for {ReactionRemoveAllEvent}
  class ReactionRemoveAllEventHandler < EventHandler
    def matches?(event)
      # Check for the proper event type
      return false unless event.is_a? ReactionRemoveAllEvent

      [
        matches_all(@attributes[:message], event.message_id) do |a, e|
          a == e
        end,
        matches_all(@attributes[:in], event.channel) do |a, e|
          case a
          when String
            # Make sure to remove the "#" from channel names in case it was specified
            a.delete('#') == e.name
          when Integer
            a == e.id
          else
            a == e
          end
        end
      ].reduce(true, &:&)
    end
  end
end
