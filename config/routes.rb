Spree::Core::Engine.add_routes do
  # PayFast ITN (Instant Transaction Notification) — async webhook from PayFast
  post '/payfast/itn',    to: 'payfast#itn',    as: :payfast_itn

  # Return URL — customer lands here after successful payment on PayFast portal
  get  '/payfast/return', to: 'payfast#return',  as: :payfast_return

  # Cancel URL — customer lands here after cancelling on PayFast portal
  get  '/payfast/cancel', to: 'payfast#cancel',  as: :payfast_cancel
end
