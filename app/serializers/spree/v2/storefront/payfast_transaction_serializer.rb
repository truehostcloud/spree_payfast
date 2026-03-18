module Spree
  module V2
    module Storefront
      class PayfastTransactionSerializer < BaseSerializer
        set_type :payfast_transaction

        attributes :m_payment_id,
                   :pf_payment_id,
                   :payment_status,
                   :amount_gross,
                   :amount_fee,
                   :amount_net,
                   :item_name,
                   :raw_itn_data,
                   :status,
                   :created_at,
                   :updated_at
      end
    end
  end
end
