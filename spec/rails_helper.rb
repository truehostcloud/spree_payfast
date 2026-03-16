# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

require 'bundler/setup'
require 'active_support'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/core_ext/object/blank'

begin
  require 'spree/testing_support/rspec'
rescue LoadError
  # Optional in minimal extension-only test environments.
end

unless defined?(Spree::Gateway)
  module Spree
    class Gateway
      class << self
        def preference(name, _type, default: nil)
          preference_defaults[name] = default if !default.nil? && !preference_defaults.key?(name)
          attr_accessor "preferred_#{name}"
        end

        def preference_defaults
          @preference_defaults ||= {}
        end
      end

      attr_accessor :name

      def initialize(name: nil, **_options)
        @name = name
        self.class.preference_defaults.each do |key, value|
          public_send("preferred_#{key}=", value)
        end
      end

      def preferences=(values)
        values.each { |key, value| public_send("preferred_#{key}=", value) }
      end
    end
  end
end

unless defined?(ActiveMerchant::Billing::Response)
  module ActiveMerchant
    module Billing
      class Response
        attr_reader :message, :params, :authorization

        def initialize(success, message, params = {}, options = {})
          @success = success
          @message = message
          @params = params
          @authorization = options[:authorization]
        end

        def success?
          @success
        end
      end
    end
  end
end

require_relative '../app/models/spree/gateway/payfast'

RSpec.configure do |config|
  config.use_transactional_fixtures = true if config.respond_to?(:use_transactional_fixtures=)
end
