# frozen_string_literal: true

module SpreePayfast
  module Itn
    class TransactionProcessor
      def initialize(order:, payment_method:, params:)
        @order = order
        @payment_method = payment_method
        @params = params
      end

      def call
        transaction = find_or_create_transaction
        return false unless transaction

        update_transaction(transaction)
        payment = payment_for_transaction(transaction)
        transition_payment(payment)
        true
      end

      private

      def find_or_create_transaction
        return unless @payment_method && @order

        source = SpreePayfast::PayfastTransaction
                 .where(m_payment_id: @order.number, payment_method_id: @payment_method.id)
                 .order(created_at: :desc)
                 .first
        return source if source

        transaction_attributes = {
          payment_method: @payment_method,
          m_payment_id: @order.number,
          status: 'pending'
        }
        transaction_attributes[:user] = @order.user if @order.respond_to?(:user) && @order.user.present?

        SpreePayfast::PayfastTransaction.create!(transaction_attributes)
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn "[SpreePayfast] ITN: Failed creating transaction for order #{@order&.number} - #{e.message}"
        nil
      end

      def update_transaction(transaction)
        transaction.update!(
          pf_payment_id: @params[:pf_payment_id],
          payment_status: @params[:payment_status],
          amount_gross: @params[:amount_gross],
          amount_fee: @params[:amount_fee],
          amount_net: @params[:amount_net],
          item_name: @params[:item_name],
          raw_itn_data: itn_params_without_signature.to_json,
          status: itn_internal_status(@params[:payment_status])
        )
      end

      def payment_for_transaction(transaction)
        payment = transaction.payment
        return payment if payment

        order_payment = @order.payments.valid
                      .where(payment_method_id: @payment_method.id)
                      .order(created_at: :desc)
                      .first
        return attach_transaction_to_payment(order_payment, transaction) if order_payment

        create_payment_for_transaction(transaction)
      end

      def attach_transaction_to_payment(payment, transaction)
        payment.update_columns(
          source_id: transaction.id,
          source_type: 'SpreePayfast::PayfastTransaction',
          updated_at: Time.current
        )
        payment
      end

      def create_payment_for_transaction(transaction)
        @order.payments.create!(
          payment_method: @payment_method,
          amount: payment_amount_for_itn,
          source: transaction
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[SpreePayfast] ITN: Failed creating payment for order #{@order.number} - #{e.message}")
        nil
      end

      def transition_payment(payment)
        return unless payment

        case @params[:payment_status]
        when 'COMPLETE'
          synchronize_completed_payment!(payment)
          payment.complete! if payment.checkout? || payment.pending? || payment.processing?

          payment.order&.update_with_updater!
          complete_order_after_successful_payment
        when 'FAILED', 'CANCELLED'
          payment.failure! unless payment.failed?
          payment.order&.update_with_updater!
        end
      rescue StateMachines::InvalidTransition => e
        Rails.logger.warn "[SpreePayfast] ITN: State transition failed — #{e.message}"
      end

      def synchronize_completed_payment!(payment)
        updates = {}
        itn_amount = parsed_itn_amount
        updates[:amount] = itn_amount if itn_amount && payment.amount.to_d != itn_amount

        response_code = @params[:pf_payment_id].presence
        updates[:response_code] = response_code if response_code.present? && payment.response_code != response_code

        return if updates.empty?

        updates[:updated_at] = Time.current
        payment.update_columns(updates)
      end

      def parsed_itn_amount
        amount = BigDecimal(@params[:amount_gross].to_s)
        return amount if amount.positive?

        nil
      rescue ArgumentError
        nil
      end

      def payment_amount_for_itn
        parsed_itn_amount || @order.total
      end

      def itn_internal_status(payfast_status)
        case payfast_status
        when 'COMPLETE' then 'complete'
        when 'FAILED', 'CANCELLED' then 'failed'
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
      end

      def order_marked_paid?
        return true if @order.respond_to?(:paid?) && @order.paid?

        @order.payments.valid.where(state: 'completed').exists?
      end

      def itn_params_without_signature
        params_hash.except('signature', 'controller', 'action', 'format')
      end

      def params_hash
        @params.respond_to?(:to_unsafe_h) ? @params.to_unsafe_h : @params.to_h
      end
    end
  end
end
