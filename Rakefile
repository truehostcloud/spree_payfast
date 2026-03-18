require 'bundler/gem_tasks'
require 'spree/testing_support/extension_rake'

desc 'Generates a dummy app for testing'
task :test_app do
  ENV['LIB_NAME'] = 'spree_payfast'
  Rake::Task['extension:test_app'].invoke
end

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec)

task default: :spec
