module Spree
  module SpreePayfast
    module CheckoutControllerDecorator
      def self.prepended(base)
        base.before_action :load_payfast_payment_method
        base.helper_method :payfast_chosen?
      end

      def load_payfast_payment_method
        @payfast_payment_method = @order.store.payment_methods.find_by(type: 'Spree::Gateway::Payfast')
      end

      def payfast_chosen?
        return @order.valid_payment.payment_method.type == 'Spree::Gateway::Payfast' if @order.valid_payment.present?

        false
      end

      def update
        super

        return unless transition_succeeded_to?(:confirm) && payfast_chosen?

        redirect_to_payfast
        nil
      end

      private

      def transition_succeeded_to?(state)
        @order.state == state.to_s
      end

      def redirect_to_payfast
        gateway = @payfast_payment_method
        return unless gateway

        payment_data = gateway.build_payment_data(
          @order,
          return_url: spree.payfast_return_url,
          cancel_url: spree.payfast_cancel_url,
          notify_url: spree.payfast_itn_url
        )

        payfast_redirect_url = "#{gateway.payfast_url}?#{URI.encode_www_form(payment_data)}"

        if performed?
          response.location = payfast_redirect_url
          response.status = 302 unless response.redirect?
          return
        end

        redirect_to payfast_redirect_url, allow_other_host: true
      end
    end
  end
end

::Spree::CheckoutController.prepend(::Spree::SpreePayfast::CheckoutControllerDecorator)
