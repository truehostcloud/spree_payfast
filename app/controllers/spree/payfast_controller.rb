require 'cgi'
require 'digest'
require 'ipaddr'
require 'net/http'
require 'resolv'
require 'uri'

module Spree
  class PayfastController < Spree::BaseController
    ITN_OPEN_TIMEOUT = ENV.fetch('PAYFAST_ITN_OPEN_TIMEOUT', '2').to_f
    ITN_READ_TIMEOUT = ENV.fetch('PAYFAST_ITN_READ_TIMEOUT', '5').to_f
    ITN_IP_CACHE_TTL = ENV.fetch('PAYFAST_ITN_IP_CACHE_TTL_SECONDS', '600').to_i.seconds

    skip_before_action :verify_authenticity_token, only: [:itn]
    before_action :find_order, only: [:itn, :return, :cancel]

    # POST /payfast/itn
    # Asynchronous ITN (Instant Transaction Notification) from PayFast.
    def itn
      unless valid_itn_request?
        Rails.logger.warn "[SpreePayfast] ITN: Validation failed for order #{params[:m_payment_id]}"
        render plain: 'Invalid ITN payload', status: :bad_request and return
      end

      process_itn
      head :ok
    end

    # GET /payfast/return
    # PayFast redirects the customer here after a successful payment.
    def return
      if @order
        flash[:success] = Spree.t('payfast.payment_success')
        redirect_to spree.order_path(@order)
      else
        redirect_to spree.root_path
      end
    end

    # GET /payfast/cancel
    # PayFast redirects the customer here after cancellation.
    def cancel
      if @order
        flash[:error] = Spree.t('payfast.payment_cancelled')
        redirect_to spree.checkout_path
      else
        redirect_to spree.root_path
      end
    end

    private

    def find_order
      order_number = params[:m_payment_id].presence
      @order = Spree::Order.find_by(number: order_number) if order_number
    end

    # Rebuilds the signature from the received ITN params and compares with the
    # sent signature. Returns true if they match.
    def valid_itn_request?
      signature_valid, signature_ms = timed_itn_check { valid_itn_signature? }
      unless signature_valid
        Rails.logger.info(
          "[SpreePayfast] ITN checks order=#{params[:m_payment_id]} " \
          "signature=false(#{signature_ms}ms)"
        )
        return false
      end

      source_ip_valid, source_ip_ms = timed_itn_check { valid_itn_source_ip? }
      amount_valid, amount_ms = timed_itn_check { valid_itn_amount? }
      server_confirmation_valid, server_ms = timed_itn_check { valid_itn_server_confirmation? }

      Rails.logger.info(
        "[SpreePayfast] ITN checks order=#{params[:m_payment_id]} " \
        "signature=#{signature_valid}(#{signature_ms}ms) " \
        "ip=#{source_ip_valid}(#{source_ip_ms}ms) " \
        "amount=#{amount_valid}(#{amount_ms}ms) " \
        "server=#{server_confirmation_valid}(#{server_ms}ms)"
      )

      signature_valid && source_ip_valid && amount_valid && server_confirmation_valid
    end

    def valid_itn_signature?
      payment_method = payfast_payment_method
      return false unless payment_method

      received_signature = params[:signature].to_s
      return false if received_signature.blank?

      expected_signatures = signature_payload_variants(payment_method.preferred_passphrase)
                            .map { |payload| Digest::MD5.hexdigest(payload) }
      valid = expected_signatures.any? { |expected| secure_compare(expected, received_signature) }

      unless valid
        Rails.logger.warn(
          "[SpreePayfast] ITN signature mismatch order=#{params[:m_payment_id]} " \
          "received=#{received_signature} expected=#{expected_signatures.join(',')}"
        )
      end

      valid
    end

    def valid_itn_source_ip?
      remote_ip = request.remote_ip.to_s
      return false if remote_ip.blank?

      valid_ips = payfast_valid_ips
      return false if valid_ips.empty?

      valid_ips.include?(remote_ip)
    rescue StandardError => e
      Rails.logger.warn("[SpreePayfast] ITN: IP validation error - #{e.message}")
      false
    end

    def valid_itn_amount?
      return false unless @order

      received_amount = BigDecimal(params[:amount_gross].to_s)
      expected_amount = BigDecimal(@order.total.to_s)

      (received_amount - expected_amount).abs <= BigDecimal('0.01')
    rescue ArgumentError
      false
    end

    def valid_itn_server_confirmation?
      payment_method = payfast_payment_method
      return false unless payment_method

      payload = signature_payload_for_server_confirmation(payment_method.preferred_passphrase)

      payfast_validation_hosts(payment_method).any? do |host|
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
    rescue StandardError => e
      Rails.logger.warn("[SpreePayfast] ITN: Server confirmation error - #{e.message}")
      false
    end

    # Update the PayfastTransaction source and transition the Spree payment state.
    def process_itn
      transaction = find_or_build_transaction
      return unless transaction

      update_transaction(transaction)
      transition_payment(transaction)
    end

    def find_or_build_transaction
      payment_method = payfast_payment_method
      return unless payment_method && @order

      source = ::SpreePayfast::PayfastTransaction
                 .where(m_payment_id: @order.number, payment_method_id: payment_method.id)
                 .last

      unless source
        Rails.logger.warn "[SpreePayfast] ITN: No PayfastTransaction found for order #{@order.number}"
      end

      source
    end

    def update_transaction(transaction)
      transaction.update!(
        pf_payment_id:  params[:pf_payment_id],
        payment_status: params[:payment_status],
        amount_gross:   params[:amount_gross],
        amount_fee:     params[:amount_fee],
        amount_net:     params[:amount_net],
        item_name:      params[:item_name],
        raw_itn_data:   itn_params_without_signature.to_json,
        status:         itn_internal_status(params[:payment_status])
      )
    end

    def transition_payment(transaction)
      payment = transaction.payment
      return unless payment

      case params[:payment_status]
      when 'COMPLETE'
        if payment.checkout? || payment.pending? || payment.processing?
          payment.complete!
        end

        payment.order&.update_with_updater!
        complete_order_after_successful_payment
        Rails.logger.info "[SpreePayfast] ITN: Payment #{payment.number} completed for order #{@order.number}"
      when 'FAILED', 'CANCELLED'
        payment.failure! unless payment.failed?
        Rails.logger.info "[SpreePayfast] ITN: Payment #{payment.number} #{params[:payment_status]} for order #{@order.number}"
      end
    rescue StateMachines::InvalidTransition => e
      Rails.logger.warn "[SpreePayfast] ITN: State transition failed — #{e.message}"
    end

    def itn_internal_status(payfast_status)
      case payfast_status
      when 'COMPLETE'   then 'complete'
      when 'FAILED'     then 'failed'
      when 'CANCELLED'  then 'failed'
      else 'pending'
      end
    end

    def complete_order_after_successful_payment
      return unless @order

      @order.reload
      @order.update_with_updater!
      return if @order.completed?

      try_complete_order_via_checkout_flow
      finalize_paid_order_from_itn unless @order.reload.completed?

      return if @order.completed?

      Rails.logger.info(
        "[SpreePayfast] ITN: Order #{@order.number} not completed after successful payment " \
        "(state=#{@order.state}, payment_state=#{@order.payment_state})"
      )
    rescue StandardError => e
      Rails.logger.warn "[SpreePayfast] ITN: Order completion failed for #{@order.number} - #{e.message}"
    end

    def try_complete_order_via_checkout_flow
      if @order.respond_to?(:can_complete?) && @order.can_complete?
        @order.complete!
      elsif @order.state == 'confirm'
        @order.next!
      end
    rescue StateMachines::InvalidTransition => e
      Rails.logger.warn "[SpreePayfast] ITN: Order completion transition failed for #{@order.number} - #{e.message}"
    end

    def finalize_paid_order_from_itn
      return unless order_marked_paid?

      @order.update_columns(state: 'complete', completed_at: Time.current, updated_at: Time.current)
      @order.finalize!
      @order.update_with_updater!

      Rails.logger.info "[SpreePayfast] ITN: Order #{@order.number} finalized from ITN fallback"
    end

    def order_marked_paid?
      return true if @order.respond_to?(:paid?) && @order.paid?

      @order.payments.valid.where(state: 'completed').exists?
    end

    def payfast_payment_method
      Spree::PaymentMethod.find_by(type: 'Spree::Gateway::Payfast', active: true)
    end

    def payfast_valid_ips
      cached_ips = self.class.instance_variable_get(:@payfast_valid_ips)
      cached_at = self.class.instance_variable_get(:@payfast_valid_ips_fetched_at)
      if cached_ips.present? && cached_at.present? && cached_at >= ITN_IP_CACHE_TTL.ago
        return cached_ips
      end

      hosts = %w[
        www.payfast.co.za
        sandbox.payfast.co.za
        w1w.payfast.co.za
        w2w.payfast.co.za
      ]

      resolved_ips = hosts.flat_map { |hostname| Resolv.getaddresses(hostname) }
                         .uniq
                         .select { |ip| valid_ipv4?(ip) }

      self.class.instance_variable_set(:@payfast_valid_ips, resolved_ips)
      self.class.instance_variable_set(:@payfast_valid_ips_fetched_at, Time.current)
      resolved_ips
    end

    def valid_ipv4?(address)
      IPAddr.new(address).ipv4?
    rescue IPAddr::InvalidAddressError
      false
    end

    def payfast_validation_hosts(payment_method)
      preferred_host = payment_method.preferred_test_mode ? 'sandbox.payfast.co.za' : 'www.payfast.co.za'
      ([preferred_host] + %w[www.payfast.co.za sandbox.payfast.co.za]).uniq
    end

    def signature_payload_base
      itn_payload_pairs
        .reject { |key, _value| key.to_s == 'signature' }
        .map { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }
        .join('&')
    end

    def itn_payload_pairs
      body_params = request.request_parameters.presence || params.to_unsafe_h
      body_params
        .except('controller', 'action', 'format')
        .map { |key, value| [key, value] }
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

    def timed_itn_check
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      duration_ms = ((finished_at - started_at) * 1000).round

      [result, duration_ms]
    end

    def secure_compare(left, right)
      return false if left.blank? || right.blank?
      return false unless left.bytesize == right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def itn_params_without_signature
      params.permit!.to_h.except('signature', 'controller', 'action', 'format')
    end
  end
end
