require 'spec_helper'

RSpec.describe Spree::Gateway::Payfast, type: :model do
  let(:gateway) { described_class.new(name: 'PayFast') }

  before do
    gateway.preferences = {
      merchant_id:  '10000100',
      merchant_key: '46f0cd694581a',
      passphrase:   'spree123',
      test_mode:    true
    }
  end

  describe '#method_type' do
    it 'returns payfast' do
      expect(gateway.method_type).to eq('payfast')
    end
  end

  describe '#payfast_url' do
    context 'when test_mode is true' do
      it 'returns the sandbox URL' do
        expect(gateway.payfast_url).to eq('https://sandbox.payfast.co.za/eng/process')
      end
    end

    context 'when test_mode is false' do
      before { gateway.preferred_test_mode = false }

      it 'returns the live URL' do
        expect(gateway.payfast_url).to eq('https://www.payfast.co.za/eng/process')
      end
    end
  end

  describe '#generate_signature' do
    it 'generates the correct MD5 signature matching PayFast field order and encoding' do
      data = {
        amount: '100.00',
        item_name: 'Test Item',
        return_url: 'http://example.com/return',
        merchant_key: '46f0cd694581a',
        merchant_id: '10000100'
      }

      expected_string = [
        'merchant_id=10000100&merchant_key=46f0cd694581a',
        'return_url=http%3A%2F%2Fexample.com%2Freturn&amount=100.00',
        'item_name=Test+Item&passphrase=spree123'
      ].join('&')
      expected_md5 = Digest::MD5.hexdigest(expected_string)

      expect(gateway.generate_signature(data)).to eq(expected_md5)
    end

    it 'normalizes plus signs to spaces before encoding' do
      data = {
        merchant_id: '10000100',
        merchant_key: '46f0cd694581a',
        item_name: 'A+B Product'
      }

      expected_string = 'merchant_id=10000100&merchant_key=46f0cd694581a&item_name=A+B+Product&passphrase=spree123'
      expect(gateway.generate_signature(data)).to eq(Digest::MD5.hexdigest(expected_string))
    end

    it 'includes extra keys after known checkout fields in their original order' do
      data = {
        merchant_key: '46f0cd694581a',
        merchant_id: '10000100',
        payment_status: 'COMPLETE',
        amount_gross: '100.00'
      }

      expected_string = [
        'merchant_id=10000100&merchant_key=46f0cd694581a',
        'payment_status=COMPLETE&amount_gross=100.00&passphrase=spree123'
      ].join('&')

      expect(gateway.generate_signature(data)).to eq(Digest::MD5.hexdigest(expected_string))
    end
  end

  describe '#build_payment_data' do
    let(:order) { double('Spree::Order', number: 'R123456789', email: 'test@example.com', total: 150.5, store: double(name: 'Test Store'), billing_address: double(full_name: 'John Doe')) }

    it 'assembles the correct hash of parameters and includes a valid signature' do
      data = gateway.build_payment_data(
        order,
        return_url: 'http://example.com/return',
        cancel_url: 'http://example.com/cancel',
        notify_url: 'http://example.com/itn'
      )

      expect(data[:merchant_id]).to eq('10000100')
      expect(data[:merchant_key]).to eq('46f0cd694581a')
      expect(data[:return_url]).to eq('http://example.com/return')
      expect(data[:cancel_url]).to eq('http://example.com/cancel')
      expect(data[:notify_url]).to eq('http://example.com/itn')
      expect(data[:name_first]).to eq('John')
      expect(data[:name_last]).to eq('Doe')
      expect(data[:email_address]).to eq('test@example.com')
      expect(data[:m_payment_id]).to eq('R123456789')
      expect(data[:amount]).to eq('150.50')
      expect(data[:item_name]).to eq('Order #R123456789 from Test Store')

      expect(data.key?(:signature)).to be true
      # Validate signature is correct MD5 hash of the assembled fields
      filtered_data = data.reject { |k, _v| k == :signature }
      expect(data[:signature]).to eq(gateway.generate_signature(filtered_data))
    end
  end
end
