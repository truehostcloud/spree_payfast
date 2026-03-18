# frozen_string_literal: true

module Spree
  # Controller handling PayFast payment notifications and redirects.
  class PayfastController < Spree::BaseController
    skip_before_action :verify_authenticity_token, only: [:itn]
    before_action :find_order, only: %i[itn return cancel]

    # POST /payfast/itn
    # Asynchronous ITN (Instant Transaction Notification) from PayFast.
    def itn
      payment_method = payfast_payment_method
      validator = ::SpreePayfast::Itn::RequestValidator.new(
        request: request,
        params: params,
        order: @order,
        payment_method: payment_method
      )

      unless validator.valid?
        render plain: 'Invalid ITN payload', status: :bad_request and return
      end

      ::SpreePayfast::Itn::TransactionProcessor.new(
        order: @order,
        payment_method: payment_method,
        params: params
      ).call

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

    def payfast_payment_method
      return if @order.blank?

      payment_method_from_order || payment_method_from_store
    end

    def payment_method_from_order
      @order.payments.valid.includes(:payment_method)
            .map(&:payment_method)
            .find { |method| method&.type == 'Spree::Gateway::Payfast' }
    end

    def payment_method_from_store
      @order.store.payment_methods.find_by(type: 'Spree::Gateway::Payfast', active: true) ||
        @order.store.payment_methods.find_by(type: 'Spree::Gateway::Payfast')
    end
  end
end

