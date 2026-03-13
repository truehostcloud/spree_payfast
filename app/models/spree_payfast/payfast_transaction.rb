module SpreePayfast
  class PayfastTransaction < ApplicationRecord
    self.table_name = 'spree_payfast_transactions'

    attr_accessor :imported

    has_one :payment, as: :source, class_name: 'Spree::Payment', dependent: :destroy
    has_one :order, through: :payment, dependent: :destroy
    belongs_to :payment_method, class_name: 'Spree::PaymentMethod'
    belongs_to :user, class_name: 'Spree::User', optional: true

    validates :m_payment_id, presence: true
    validates :status, presence: true

    # Human-readable label used in admin payment views.
    def display_number
      pf_payment_id.presence || m_payment_id
    end
  end
end
