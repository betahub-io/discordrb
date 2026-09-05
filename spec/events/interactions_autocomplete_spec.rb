# frozen_string_literal: true

require 'discordrb'

describe Discordrb::Interactions::OptionBuilder do
  it 'serializes the autocomplete flag on string options' do
    builder = described_class.new
    builder.string('key', 'Configuration key', required: true, autocomplete: true)

    expect(builder.to_a.first[:autocomplete]).to be true
  end

  it 'omits autocomplete when not requested' do
    builder = described_class.new
    builder.string('key', 'Configuration key', required: true)

    expect(builder.to_a.first).not_to have_key(:autocomplete)
  end
end

describe Discordrb::Events::ApplicationCommandAutocompleteEvent do
  let(:bot) { double('bot') }

  before { allow(bot).to receive(:ensure_user).and_return(double('user', id: 42)) }

  let(:data) do
    {
      'id' => '1',
      'application_id' => '2',
      'token' => 'tok',
      'version' => 1,
      'type' => 4,
      'guild_id' => '555',
      'channel_id' => '777',
      'user' => { 'id' => '42' },
      'data' => {
        'id' => '10',
        'name' => 'set',
        'options' => [
          { 'name' => 'key', 'type' => 3, 'value' => 'cust', 'focused' => true }
        ]
      }
    }
  end

  it 'exposes the focused option name and its partial value' do
    event = described_class.new(data, bot)

    expect(event.command_name).to eq(:set)
    expect(event.focused_option).to eq(:key)
    expect(event.focused_value).to eq('cust')
  end

  it 'responds with choices through the autocomplete API' do
    event = described_class.new(data, bot)
    choices = [{ name: 'custom_field:foo', value: 'custom_field:foo' }]

    expect(Discordrb::API::Interaction).to receive(:create_interaction_autocomplete_response)
      .with('tok', 1, choices)

    event.respond_with_choices(choices)
  end
end
