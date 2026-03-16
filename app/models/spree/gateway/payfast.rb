require 'digest'
require 'cgi'

module Spree
  class Gateway::Payfast < Gateway
    PAYFAST_LIVE_URL = 'https://www.payfast.co.za/eng/process'
    PAYFAST_SANDBOX_URL = 'https://sandbox.payfast.co.za/eng/process'
    SIGNATURE_FIELD_ORDER = %i[
      merchant_id
      merchant_key
      return_url
      cancel_url
      notify_url
      name_first
      name_last
      email_address
      m_payment_id
      amount
      item_name
      item_description
      custom_int1
      custom_int2
      custom_int3
      custom_int4
      custom_int5
      custom_str1
      custom_str2
      custom_str3
      custom_str4
      custom_str5
      email_confirmation
      confirmation_address
      payment_method
      subscription_type
      billing_date
      recurring_amount
      frequency
      cycles
    ].freeze

    preference :merchant_id, :string
    preference :merchant_key, :string
    preference :passphrase, :string
    preference :test_mode, :boolean, default: true

    def method_type
      'payfast'
    end

    def payment_source_class
      ::SpreePayfast::PayfastTransaction
    end

    def source_required?
      true
    end

    def auto_capture?
      false
    end

    def supports?(source)
      source.instance_of?(payment_source_class)
    end

    def payfast_url
      preferred_test_mode ? PAYFAST_SANDBOX_URL : PAYFAST_LIVE_URL
    end

    def build_payment_data(order, return_url:, cancel_url:, notify_url:)
      email = order.email.presence || ''
      name_parts = order.billing_address&.full_name.to_s.split(' ', 2)
      first_name = name_parts.first.to_s
      last_name = name_parts.last.to_s

      data = {
        merchant_id: preferred_merchant_id,
        merchant_key: preferred_merchant_key,
        return_url: return_url,
        cancel_url: cancel_url,
        notify_url: notify_url,
        name_first: first_name,
        name_last: last_name,
        email_address: email,
        m_payment_id: order.number,
        amount: format_amount(order.total),
        item_name: "Order ##{order.number} from #{order.store.name}"
      }

      data.reject! { |_key, value| value.to_s.strip.empty? }
      data[:signature] = generate_signature(data)
      data
    end

    def generate_signature(data)
      filtered = data.reject { |key, value| key.to_s == 'signature' || value.to_s.strip.empty? }
      ordered_pairs = ordered_signature_pairs(filtered)
      param_string = ordered_pairs.map { |key, value| "#{key}=#{encode_payfast_value(value)}" }.join('&')

      passphrase = preferred_passphrase.presence
      if passphrase
        encoded_passphrase = encode_payfast_value(passphrase)
        param_string += "&passphrase=#{encoded_passphrase}"
      end

      signature = Digest::MD5.hexdigest(param_string)
      log_signature_debug(ordered_pairs, param_string, signature)
      signature
    end

    def purchase(_money_in_cents, source, _gateway_options)
      return ActiveMerchant::Billing::Response.new(false, 'PayFast: Missing payment reference') if source.m_payment_id.blank?

      authorization = source.pf_payment_id.presence || source.m_payment_id
      payment_status = source.payment_status.to_s.upcase

      case payment_status
      when 'COMPLETE'
        ActiveMerchant::Billing::Response.new(true, 'PayFast: Payment complete', {}, authorization: authorization)
      when 'FAILED', 'CANCELLED'
        ActiveMerchant::Billing::Response.new(false, "PayFast: Payment #{payment_status}", {}, authorization: authorization)
      else
        ActiveMerchant::Billing::Response.new(true, 'PayFast: Awaiting ITN confirmation', {}, authorization: authorization)
      end
    end

    def authorize(money_in_cents, source, gateway_options)
      purchase(money_in_cents, source, gateway_options)
    end

    def void(_response_code, _gateway_options)
      ActiveMerchant::Billing::Response.new(false, 'PayFast: Void is not supported')
    end

    def credit(_credit_cents, _response_code, _gateway_options)
      ActiveMerchant::Billing::Response.new(false, 'PayFast: Refunds must be processed via the PayFast Dashboard')
    end

    private

    def format_amount(amount)
      format('%.2f', amount)
    end

    def ordered_signature_pairs(data)
      source_data = data.to_h
      data_with_indifferent_access = source_data.with_indifferent_access
      ordered = []
      added_fields = {}

      SIGNATURE_FIELD_ORDER.each do |field|
        value = data_with_indifferent_access[field]
        next if value.to_s.strip.empty?

        ordered << [field, value]
        added_fields[field.to_s] = true
      end

      source_data.each do |key, value|
        key_name = key.to_s
        next if added_fields[key_name]
        next if value.to_s.strip.empty?

        ordered << [key_name, value]
      end

      ordered
    end

    def encode_payfast_value(value)
      CGI.escape(value.to_s.gsub('+', ' '))
    end

    def log_signature_debug(ordered_pairs, payload, signature)
      return unless payfast_signature_debug?

      keys = ordered_pairs.map { |key, _value| key.to_s }.join(',')
      Rails.logger.debug("[SpreePayfast] Signature keys=#{keys} payload_redacted=#{redact_signature_payload(payload)} signature=#{signature}")
      return unless payfast_signature_full_debug?

      Rails.logger.debug("[SpreePayfast] Signature payload_full=#{payload}")
    end

    def redact_signature_payload(payload)
      payload
        .gsub(/(merchant_key=)[^&]*/, '\\1[FILTERED]')
        .gsub(/(passphrase=)[^&]*/, '\\1[FILTERED]')
    end

    def payfast_signature_debug?
      ENV['PAYFAST_DEBUG_SIGNATURE'].to_s.casecmp('true').zero?
    end

    def payfast_signature_full_debug?
      ENV['PAYFAST_DEBUG_SIGNATURE_FULL'].to_s.casecmp('true').zero?
    end
  end
end
