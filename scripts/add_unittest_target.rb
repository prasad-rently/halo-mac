#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds the HaloTests unit-test bundle target (Swift Testing + @testable import
# Halo) to Halo.xcodeproj, hosted in the Halo app. Idempotent.
#
#   LANG=en_US.UTF-8 RUBYOPT="-Eutf-8" ruby scripts/add_unittest_target.rb
#
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Halo.xcodeproj', __dir__)
TESTS_DIR    = 'HaloTests'
TARGET_NAME  = 'HaloTests'
APP_TARGET   = 'Halo'

project = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == APP_TARGET }
raise "App target '#{APP_TARGET}' not found" unless app_target

# Idempotency
project.targets.select { |t| t.name == TARGET_NAME }.each do |t|
  puts "Removing existing target #{TARGET_NAME}"
  t.remove_from_project
end
if (old = project.main_group[TESTS_DIR])
  old.remove_from_project
end

test_target = project.new_target(
  :unit_test_bundle, # → com.apple.product-type.bundle.unit-test
  TARGET_NAME,
  :osx,
  '13.0'
)

host = '$(BUILT_PRODUCTS_DIR)/Halo.app/Contents/MacOS/Halo'
test_target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.halo.mac.tests'
  s['PRODUCT_NAME']             = '$(TARGET_NAME)'
  s['MACOSX_DEPLOYMENT_TARGET']  = '13.0'
  s['SDKROOT']                   = 'macosx'
  s['SWIFT_VERSION']             = '5.9'
  s['GENERATE_INFOPLIST_FILE']   = 'YES'
  s['CODE_SIGN_STYLE']           = 'Manual'
  s['DEVELOPMENT_TEAM']          = ''
  # Host the tests in the app so `@testable import Halo` resolves.
  s['TEST_HOST']                 = host
  s['BUNDLE_LOADER']             = '$(TEST_HOST)'
  s['CURRENT_PROJECT_VERSION']   = '210'
  s['MARKETING_VERSION']         = '2.1'
end

group = project.main_group.new_group(TESTS_DIR, TESTS_DIR)
swift_files = Dir.glob(File.join(File.expand_path('..', __dir__), TESTS_DIR, '*.swift')).sort
raise "No Swift files in #{TESTS_DIR}/" if swift_files.empty?
swift_files.each do |path|
  ref = group.new_reference(File.basename(path))
  test_target.add_file_references([ref])
  puts "  + #{File.basename(path)}"
end

test_target.add_dependency(app_target)
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.set_launch_target(app_target)
testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(test_target)
scheme.test_action.add_testable(testable)
scheme.save_as(PROJECT_PATH, TARGET_NAME, true)

puts "\nDone. Target '#{TARGET_NAME}' added with #{swift_files.size} files and a shared scheme."
