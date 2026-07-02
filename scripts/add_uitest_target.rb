#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds the HaloUITests XCUITest bundle target to Halo.xcodeproj and wires it
# to the Halo app target. Idempotent: re-running removes a prior HaloUITests
# target first, so it is safe to run repeatedly.
#
#   ruby scripts/add_uitest_target.rb
#
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Halo.xcodeproj', __dir__)
UITESTS_DIR  = 'HaloUITests'
TARGET_NAME  = 'HaloUITests'
APP_TARGET   = 'Halo'

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == APP_TARGET }
raise "App target '#{APP_TARGET}' not found" unless app_target

# --- Idempotency: drop any previous HaloUITests target & group -------------
project.targets.select { |t| t.name == TARGET_NAME }.each do |t|
  puts "Removing existing target #{TARGET_NAME}"
  t.remove_from_project
end
if (old_group = project.main_group[UITESTS_DIR])
  old_group.remove_from_project
end

# --- Create the UI-testing bundle target -----------------------------------
ui_target = project.new_target(
  :ui_test_bundle, # product type → com.apple.product-type.bundle.ui-testing
  TARGET_NAME,
  :osx,
  '13.0'
)

# --- Build settings (mirror the app target where it matters) ---------------
ui_target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER']   = 'com.halo.mac.uitests'
  s['PRODUCT_NAME']                = '$(TARGET_NAME)'
  s['MACOSX_DEPLOYMENT_TARGET']    = '13.0'
  s['SDKROOT']                     = 'macosx'
  s['SWIFT_VERSION']               = '5.9'
  s['GENERATE_INFOPLIST_FILE']     = 'YES'
  s['CODE_SIGN_STYLE']             = 'Manual'
  s['DEVELOPMENT_TEAM']            = ''
  s['TEST_TARGET_NAME']            = APP_TARGET
  s['SWIFT_EMIT_LOC_STRINGS']      = 'NO'
  s['CURRENT_PROJECT_VERSION']     = '210'
  s['MARKETING_VERSION']           = '2.1'
  # Let UI tests find the app under test in the same build dir.
  s['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'YES'
end

# --- Source files ----------------------------------------------------------
group = project.main_group.new_group(UITESTS_DIR, UITESTS_DIR)
swift_files = Dir.glob(File.join(File.expand_path('..', __dir__), UITESTS_DIR, '*.swift')).sort
raise "No Swift files found in #{UITESTS_DIR}/" if swift_files.empty?

swift_files.each do |path|
  ref = group.new_reference(File.basename(path))
  ui_target.add_file_references([ref])
  puts "  + #{File.basename(path)}"
end

# --- Dependency on the app target so it builds first -----------------------
ui_target.add_dependency(app_target)

# --- Register the target with the app scheme is optional; create a shared
#     scheme dedicated to the UI tests so `xcodebuild -scheme HaloUITests`
#     works out of the box. ----------------------------------------------
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_build_target(ui_target)
scheme.set_launch_target(app_target)
test_action = scheme.test_action
testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(ui_target)
test_action.add_testable(testable)
scheme.save_as(PROJECT_PATH, TARGET_NAME, true) # shared

puts "\nDone. Target '#{TARGET_NAME}' added with #{swift_files.size} files and a shared scheme."
