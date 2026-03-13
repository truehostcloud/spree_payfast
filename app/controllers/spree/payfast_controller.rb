require 'cgi'
require 'digest'

module Spree
  class PayfastController < Spree::BaseController
    skip_before_action :verify_authenticity_token, only: [:itn]
    before_action :find_order, only: [:itn, :return, :cancel]

    # POST /payfast/itn
    # Asynchronous ITN (Instant Transaction Notification) from PayFast.
    def itn
      unless valid_itn_signature?
        Rails.logger.warn "[SpreePayfast] ITN: Invalid signature for order #{params[:m_payment_id]}"
        render plain: 'Invalid signature', status: :bad_request and return
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
    def valid_itn_signature?
      payment_method = payfast_payment_method
      return false unless payment_method

      received_signature = params[:signature]
      data_without_signature = itn_params_without_signature

      expected = payment_method.generate_signature(data_without_signature)
      expected == received_signature
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

      source = SpreePayfast::PayfastTransaction
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
        payment.process! if payment.checkout? || payment.pending?
        payment.complete! if payment.processing?
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

    def payfast_payment_method
      Spree::PaymentMethod.find_by(type: 'Spree::Gateway::Payfast', active: true)
    end

    def itn_params_without_signature
      params.permit!.to_h.except('signature', 'controller', 'action', 'format')
    end
  end
end
