class CreateSpreePayfastTransactions < ActiveRecord::Migration[6.1]
  def change
    create_table :spree_payfast_transactions, if_not_exists: true do |t|
      # Order reference — Spree order number sent as m_payment_id to PayFast
      t.string  :m_payment_id,    null: false, index: true
      # PayFast's own payment reference returned via ITN
      t.string  :pf_payment_id,   index: true
      # ITN payment_status: COMPLETE, FAILED, CANCELLED
      t.string  :payment_status
      # Monetary fields from ITN
      t.decimal :amount_gross,    precision: 10, scale: 2
      t.decimal :amount_fee,      precision: 10, scale: 2
      t.decimal :amount_net,      precision: 10, scale: 2
      # For display in admin
      t.string  :item_name
      # Raw ITN params stored as JSON for audit
      t.text    :raw_itn_data
      # Internal status: pending, complete, failed
      t.string  :status,          null: false, default: 'pending'

      # Associations
      t.bigint :payment_method_id, index: true
      t.bigint :user_id,           index: true

      t.timestamps
    end
  end
end
