lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require 'spree_payfast/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'spree_payfast'
  s.version     = SpreePayfast::VERSION
  s.summary     = 'PayFast payment gateway integration for Spree Commerce'
  s.description = 'Integrates PayFast (Credit/Debit Card, Instant EFT, Zapper) as a payment ' \
                  'option in Spree Commerce using the hosted redirect (Custom Integration) flow.'
  s.required_ruby_version = '>= 3.1'

  s.author   = 'TrueHost Cloud'
  s.email    = 'dev@truehostcloud.com'
  s.homepage = 'https://github.com/truehostcloud/spree_payfast'
  s.license  = 'BSD-3-Clause'

  s.files = `git ls-files`.split("\n").reject { |f| f.match(/^spec/) && !f.match(%r{^spec/fixtures}) }
  s.require_path = 'lib'
  s.requirements << 'none'

  spree_version = '~> 5.0'
  s.add_dependency 'httparty'
  s.add_dependency 'spree', spree_version
  s.add_dependency 'spree_admin', spree_version

  s.add_development_dependency 'spree_dev_tools'
end
