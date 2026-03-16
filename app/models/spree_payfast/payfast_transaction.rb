# frozen_string_literal: true

module SpreePayfast
  # Model representing a PayFast transaction, linked to Spree payments and orders.
  class PayfastTransaction < ApplicationRecord
    self.table_name = 'spree_payfast_transactions'

    attr_accessor :imported

    has_one :payment, as: :source, class_name: 'Spree::Payment'
    has_one :order, through: :payment
    belongs_to :payment_method, class_name: 'Spree::PaymentMethod'
    belongs_to :user, class_name: 'Spree::User', optional: true

    validates :m_payment_id, presence: true
    validates :status, presence: true
    validates :payment_method, presence: true

    # Human-readable label used in admin payment views.
    def display_number
      pf_payment_id.presence || m_payment_id
    end
  end
end
