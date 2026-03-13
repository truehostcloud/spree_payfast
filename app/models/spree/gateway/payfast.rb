require 'digest'

module Spree
  class Gateway::Payfast < Gateway
    PAYFAST_LIVE_URL = 'https://www.payfast.co.za/eng/process'
    PAYFAST_SANDBOX_URL = 'https://sandbox.payfast.co.za/eng/process'

    preference :merchant_id,  :string
    preference :merchant_key, :string
    preference :passphrase,   :string
    preference :test_mode,    :boolean, default: true

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
      # PayFast uses ITN to confirm payment; we do not auto-capture on submission.
      false
    end

    def supports?(source)
      source.instance_of?(payment_source_class)
    end

    # Returns the correct PayFast engine URL based on test_mode preference.
    def payfast_url
      preferred_test_mode ? PAYFAST_SANDBOX_URL : PAYFAST_LIVE_URL
    end

    # Builds the hash of parameters to send with the redirect to PayFast.
    # @param order [Spree::Order]
    # @param return_url [String] URL PayFast redirects to after successful payment
    # @param cancel_url [String] URL PayFast redirects to after cancellation
    # @param notify_url [String] ITN endpoint URL
    # @return [Hash]
    def build_payment_data(order, return_url:, cancel_url:, notify_url:)
      email = order.email.presence || ''
      name_parts = order.billing_address&.full_name.to_s.split(' ', 2)
      first_name = name_parts.first.to_s
      last_name  = name_parts.last.to_s

      data = {
        merchant_id:  preferred_merchant_id,
        merchant_key: preferred_merchant_key,
        return_url:   return_url,
        cancel_url:   cancel_url,
        notify_url:   notify_url,
        name_first:   first_name,
        name_last:    last_name,
        email_address: email,
        m_payment_id: order.number,
        amount:       format_amount(order.total),
        item_name:    "Order ##{order.number} from #{order.store.name}"
      }

      data[:signature] = generate_signature(data)
      data
    end

    # Generates the PayFast MD5 signature from a data hash.
    # Key-value pairs are joined as a URL-encoded query string; the passphrase
    # (if set) is appended. The resulting string is MD5-hashed.
    #
    # @param data [Hash] ordered hash of parameter key-value pairs (without :signature)
    # @return [String] lowercase hex MD5 digest
    def generate_signature(data)
      filtered = data.reject { |k, _v| k.to_s == 'signature' }
      param_string = filtered.map do |k, v|
        "#{k}=#{CGI.escape(v.to_s).gsub('+', '%20')}"
      end.join('&')

      passphrase = preferred_passphrase.presence
      param_string += "&passphrase=#{CGI.escape(passphrase).gsub('+', '%20')}" if passphrase

      Digest::MD5.hexdigest(param_string)
    end

    # Called by Spree after ITN is received and we have verified the payment.
    # The actual state transition is handled in the ITN controller; this method just
    # returns success so Spree records the payment correctly.
    def purchase(_money_in_cents, source, _gateway_options)
      return ActiveMerchant::Billing::Response.new(false, 'PayFast: Missing payment reference') if source.m_payment_id.blank?

      if source.payment_status == 'COMPLETE'
        ActiveMerchant::Billing::Response.new(true, 'PayFast: Payment complete', {}, authorization: source.pf_payment_id)
      else
        ActiveMerchant::Billing::Response.new(false, "PayFast: Payment #{source.payment_status}")
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

    # Formats a BigDecimal/Float as "0.00" string required by PayFast.
    def format_amount(amount)
      format('%.2f', amount)
    end
  end
end
