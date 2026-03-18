# frozen_string_literal: true

class HardenSpreePayfastTransactionsConstraints < ActiveRecord::Migration[6.1]
  TABLE_NAME = :spree_payfast_transactions
  UNIQUE_TRANSACTION_INDEX = :idx_spree_payfast_transactions_unique_method_order

  def up
    backfill_payment_method_id_from_payments
    remove_rows_missing_required_columns
    deduplicate_by_payment_method_and_order

    change_column_null TABLE_NAME, :m_payment_id, false
    change_column_null TABLE_NAME, :payment_method_id, false

    add_foreign_key TABLE_NAME, :spree_payment_methods, column: :payment_method_id unless foreign_key_exists?(TABLE_NAME, :spree_payment_methods, column: :payment_method_id)
    add_foreign_key TABLE_NAME, :spree_users, column: :user_id unless foreign_key_exists?(TABLE_NAME, :spree_users, column: :user_id)

    add_index TABLE_NAME, %i[payment_method_id m_payment_id], unique: true, name: UNIQUE_TRANSACTION_INDEX unless index_exists?(TABLE_NAME, %i[payment_method_id m_payment_id], unique: true, name: UNIQUE_TRANSACTION_INDEX)
  end

  def down
    remove_index TABLE_NAME, name: UNIQUE_TRANSACTION_INDEX if index_exists?(TABLE_NAME, name: UNIQUE_TRANSACTION_INDEX)
    remove_foreign_key TABLE_NAME, column: :payment_method_id if foreign_key_exists?(TABLE_NAME, column: :payment_method_id)
    remove_foreign_key TABLE_NAME, column: :user_id if foreign_key_exists?(TABLE_NAME, column: :user_id)

    change_column_null TABLE_NAME, :payment_method_id, true
  end

  private

  def backfill_payment_method_id_from_payments
    execute <<~SQL.squish
      UPDATE #{TABLE_NAME} transactions
      SET payment_method_id = payments.payment_method_id
      FROM spree_payments payments
      WHERE payments.source_id = transactions.id
        AND payments.source_type = 'SpreePayfast::PayfastTransaction'
        AND transactions.payment_method_id IS NULL
    SQL
  rescue ActiveRecord::StatementInvalid
    # Adapter may not support FROM updates; fallback via Ruby update loop.
    rows = select_all(<<~SQL.squish)
      SELECT transactions.id AS id, payments.payment_method_id AS payment_method_id
      FROM #{TABLE_NAME} transactions
      INNER JOIN spree_payments payments
        ON payments.source_id = transactions.id
       AND payments.source_type = 'SpreePayfast::PayfastTransaction'
      WHERE transactions.payment_method_id IS NULL
    SQL

    rows.each do |row|
      execute <<~SQL.squish
        UPDATE #{TABLE_NAME}
        SET payment_method_id = #{connection.quote(row['payment_method_id'])}
        WHERE id = #{connection.quote(row['id'])}
      SQL
    end
  end

  def remove_rows_missing_required_columns
    execute <<~SQL.squish
      DELETE FROM #{TABLE_NAME}
      WHERE m_payment_id IS NULL
         OR m_payment_id = ''
         OR payment_method_id IS NULL
    SQL
  end

  def deduplicate_by_payment_method_and_order
    duplicate_rows = select_all(<<~SQL.squish)
      SELECT id, payment_method_id, m_payment_id
      FROM #{TABLE_NAME}
      ORDER BY payment_method_id ASC, m_payment_id ASC, updated_at DESC, id DESC
    SQL

    seen_pairs = {}
    duplicate_ids = []

    duplicate_rows.each do |row|
      pair_key = "#{row['payment_method_id']}::#{row['m_payment_id']}"
      if seen_pairs[pair_key]
        duplicate_ids << row['id']
      else
        seen_pairs[pair_key] = true
      end
    end

    return if duplicate_ids.empty?

    execute <<~SQL.squish
      DELETE FROM #{TABLE_NAME}
      WHERE id IN (#{duplicate_ids.map { |id| connection.quote(id) }.join(',')})
    SQL
  end
end
