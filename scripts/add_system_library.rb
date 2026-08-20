#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Links a system library/framework (e.g. libsqlite3.tbd) into the Halo app
# target's Frameworks build phase. Idempotent — skips if already linked.
# Mirrors the existing IOKit.framework/SystemConfiguration.framework pattern
# in project.pbxproj, but via the xcodeproj gem rather than hand-editing
# UUIDs. Usage:
#
#   LANG=en_US.UTF-8 RUBYOPT="-Eutf-8" ruby scripts/add_system_library.rb usr/lib/libsqlite3.tbd
#
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Halo.xcodeproj', __dir__)
APP_TARGET   = 'Halo'

sdk_relative_path = ARGV[0]
abort 'Pass an SDK-relative path, e.g. usr/lib/libsqlite3.tbd' if sdk_relative_path.nil?

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == APP_TARGET }
abort "Target '#{APP_TARGET}' not found" unless target

frameworks_group = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')

existing_ref = frameworks_group.files.find { |f| f.path == sdk_relative_path }
already_linked = existing_ref && target.frameworks_build_phase.files.any? { |bf| bf.file_ref == existing_ref }

if already_linked
  puts "  = already linked: #{sdk_relative_path}"
else
  file_ref = existing_ref || frameworks_group.new_file(sdk_relative_path, :sdk_root)
  target.frameworks_build_phase.add_file_reference(file_ref)
  puts "  + linked to #{APP_TARGET}: #{sdk_relative_path}"
end

project.save
puts 'Saved.'
