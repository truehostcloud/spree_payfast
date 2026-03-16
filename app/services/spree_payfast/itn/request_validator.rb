# frozen_string_literal: true

require 'cgi'
require 'digest'
require 'ipaddr'
require 'net/http'
require 'resolv'
require 'uri'

module SpreePayfast
  module Itn
    # Service class responsible for validating incoming ITN requests from PayFast.
    # It performs multiple checks to ensure the request is legitimate before processing the transaction.
    class RequestValidator
      ITN_OPEN_TIMEOUT = ENV.fetch('PAYFAST_ITN_OPEN_TIMEOUT', '2').to_f
      ITN_READ_TIMEOUT = ENV.fetch('PAYFAST_ITN_READ_TIMEOUT', '5').to_f
      ITN_IP_CACHE_TTL = ENV.fetch('PAYFAST_ITN_IP_CACHE_TTL_SECONDS', '600').to_i.seconds
      DEFAULT_PAYFAST_VALIDATION_HOSTS = %w[
        www.payfast.co.za
        sandbox.payfast.co.za
        w1w.payfast.co.za
        w2w.payfast.co.za
      ].freeze

      def initialize(request:, params:, order:, payment_method:)
        @request = request
        @params = params
        @order = order
        @payment_method = payment_method
      end

      def valid?
        valid_signature? && valid_source_ip? && valid_amount? && valid_server_confirmation?
      end

      private

      def valid_signature?
        return false unless @payment_method

        received_signature = @params[:signature].to_s
        return false if received_signature.blank?

        expected_signatures = signature_payload_variants(@payment_method.preferred_passphrase)
                              .map { |payload| Digest::MD5.hexdigest(payload) }
        expected_signatures.any? { |expected| secure_compare(expected, received_signature) }
      end

      def valid_source_ip?
        remote_ip = @request.remote_ip.to_s
        return false if remote_ip.blank?

        valid_ips = payfast_valid_ips
        return false if valid_ips.empty?

        valid_ips.include?(remote_ip)
      rescue StandardError
        false
      end

      def valid_amount?
        return false unless @order

        received_amount = BigDecimal(@params[:amount_gross].to_s)
        expected_amount = BigDecimal(@order.total.to_s)

        (received_amount - expected_amount).abs <= BigDecimal('0.01')
      rescue ArgumentError
        false
      end

      def valid_server_confirmation?
        return false unless @payment_method

        payload = signature_payload_for_server_confirmation(@payment_method.preferred_passphrase)

        payfast_validation_hosts.any? do |host|
          uri = URI.parse("https://#{host}/eng/query/validate")

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: ITN_OPEN_TIMEOUT,
            read_timeout: ITN_READ_TIMEOUT
          ) do |http|
            request = Net::HTTP::Post.new(uri.request_uri)
            request['Content-Type'] = 'application/x-www-form-urlencoded'
            request.body = payload
            http.request(request)
          end

          response.body.to_s.strip == 'VALID'
        end
      rescue StandardError
        false
      end

      def payfast_valid_ips
        cached_ips = self.class.instance_variable_get(:@payfast_valid_ips)
        cached_at = self.class.instance_variable_get(:@payfast_valid_ips_fetched_at)
        return cached_ips if cached_ips.present? && cached_at.present? && cached_at >= ITN_IP_CACHE_TTL.ago

        resolved_ips = resolve_payfast_ips
        return cache_resolved_ips(resolved_ips) if resolved_ips.present?

        cached_ips || []
      end

      def resolve_payfast_ips
        configured_payfast_hosts.flat_map { |hostname| Resolv.getaddresses(hostname) }
             .uniq
             .select { |ip| valid_ipv4?(ip) }
      rescue StandardError
        []
      end

      def cache_resolved_ips(resolved_ips)
        self.class.instance_variable_set(:@payfast_valid_ips, resolved_ips)
        self.class.instance_variable_set(:@payfast_valid_ips_fetched_at, Time.current)
        resolved_ips
      end

      def valid_ipv4?(address)
        IPAddr.new(address).ipv4?
      rescue IPAddr::InvalidAddressError
        false
      end

      def payfast_validation_hosts
        preferred_host = @payment_method.preferred_test_mode ? 'sandbox.payfast.co.za' : 'www.payfast.co.za'
        ([preferred_host] + configured_payfast_hosts).uniq
      end

      def configured_payfast_hosts
        ENV.fetch('PAYFAST_VALIDATION_HOSTS', DEFAULT_PAYFAST_VALIDATION_HOSTS.join(','))
           .split(',')
           .map(&:strip)
           .reject(&:blank?)
      end

      def signature_payload_base
        itn_payload_pairs
          .reject { |key, _value| key.to_s == 'signature' }
          .map { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }
          .join('&')
      end

      def itn_payload_pairs
        body_params = @request.request_parameters.presence || raw_params_hash
        body_params
          .except('controller', 'action', 'format')
          .map { |key, value| [key, value] }
      end

      def raw_params_hash
        @params.respond_to?(:to_unsafe_h) ? @params.to_unsafe_h : @params.to_h
      end

      def signature_payload_variants(passphrase)
        payload = signature_payload_base
        variants = [payload]
        return variants if passphrase.blank?

        encoded_passphrase = CGI.escape(passphrase.to_s.gsub('+', ' '))
        variants << "#{payload}&passphrase=#{encoded_passphrase}"
        variants
      end

      def signature_payload_for_server_confirmation(passphrase)
        payload = signature_payload_base
        return payload if passphrase.blank?

        encoded_passphrase = CGI.escape(passphrase.to_s.gsub('+', ' '))
        "#{payload}&passphrase=#{encoded_passphrase}"
      end

      def secure_compare(left, right)
        return false if left.blank? || right.blank?
        return false unless left.bytesize == right.bytesize

        ActiveSupport::SecurityUtils.secure_compare(left, right)
      end
    end
  end
end
