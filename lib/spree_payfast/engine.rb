require_relative 'configuration'

module SpreePayfast
  class Engine < Rails::Engine
    require 'spree/core'
    isolate_namespace Spree
    engine_name 'spree_payfast'

    config.after_initialize do |app|
      app.config.spree.payment_methods << Spree::Gateway::Payfast
    end

    config.generators do |g|
      g.test_framework :rspec
    end

    initializer 'spree_payfast.environment', before: :load_config_initializers do |_app|
      SpreePayfast::Config = SpreePayfast::Configuration.new
    end

    def self.activate
      Dir.glob(File.join(File.dirname(__FILE__), '../../app/**/*_decorator*.rb')) do |c|
        Rails.configuration.cache_classes ? require(c) : load(c)
      end
    end

    config.to_prepare(&method(:activate).to_proc)
  end
end
