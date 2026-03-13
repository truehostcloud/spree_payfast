module SpreePayfast
  module OrderDecorator
    def update_from_params(params, permitted_params, request_env = {})
      @updating_params = params

      if payfast_checkout?
        valid_payment.invalidate! if valid_payment.present? && !valid_payment_uses_payfast?
        update_from_params_using_payfast(params, permitted_params, request_env)
      else
        super(params, permitted_params, request_env)
      end
    end

    def update_from_params_using_payfast(params, permitted_params, request_env = {})
      success = false
      @updating_params = params
      run_callbacks :updating_from_params do
        attributes = if @updating_params[:order]
                       @updating_params[:order].permit(permitted_params).delete_if { |_k, v| v.nil? }
                     else
                       {}
                     end
        attributes[:payments_attributes].first[:request_env] = request_env if attributes[:payments_attributes]

        attributes = build_payfast_source_in_attributes(attributes: attributes)

        success = update(attributes)
        set_shipments_cost if shipments.any?
      end
      @updating_params = nil
      success
    end

    # Force the confirm step so the redirect to PayFast can happen cleanly.
    def confirmation_required?
      return true if payfast_checkout?

      super
    end

    def valid_payment
      payments.valid.first
    end

    # True when the currently selected payment method is PayFast.
    def payfast_checkout?
      # For GET requests or non-payment steps, rely on the persisted valid payment.
      if @updating_params.nil? || @updating_params[:state] != 'payment'
        return valid_payment.payment_method.type == 'Spree::Gateway::Payfast' unless valid_payment.nil?

        return false
      end

      # For the POST on the `payment` step, check params.
      payfast_in_payment_attributes?
    end

    private

    # Creates or finds the PayfastTransaction source record and attaches it to
    # the payments_attributes before the order is updated. Works for both
    # authenticated users and guests.
    def build_payfast_source_in_attributes(attributes:)
      payment_attributes = attributes[:payments_attributes]&.first
      return attributes unless payfast_checkout? && payment_attributes.present?

      payment_method = store.payment_methods.find_by(type: 'Spree::Gateway::Payfast')
      return attributes unless payment_method

      transaction = ::SpreePayfast::PayfastTransaction
                      .where(m_payment_id: number, payment_method_id: payment_method.id)
                      .last

      if transaction.nil?
        transaction_attrs = {
          payment_method: payment_method,
          m_payment_id:   number,
          status:         'pending'
        }
        transaction_attrs[:user] = user if user.present?
        transaction = ::SpreePayfast::PayfastTransaction.create!(transaction_attrs)
      end

      attributes[:payments_attributes].first[:source]            = transaction
      attributes[:payments_attributes].first[:payment_method_id] = transaction.payment_method_id
      attributes[:payments_attributes].first.delete(:source_attributes)

      attributes
    end

    def payfast_gateway
      store.payment_methods.find_by(type: 'Spree::Gateway::Payfast')
    end

    def payfast_in_payment_attributes?
      return false if @updating_params.nil?

      payment_attrs = @updating_params.dig(:order, :payments_attributes)
      return false if payment_attrs.nil?
      return false if payment_attrs.first[:payment_method_id].nil?
      return false if payfast_gateway.nil?

      payfast_gateway.id == payment_attrs.first[:payment_method_id].to_i
    end

    def valid_payment_uses_payfast?
      return false if valid_payment.nil?

      valid_payment.payment_method.type == 'Spree::Gateway::Payfast'
    end
  end
end

::Spree::Order.prepend(SpreePayfast::OrderDecorator)
