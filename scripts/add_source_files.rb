#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds source files to the Halo app target's Sources build phase.
# Idempotent — skips files already present. Usage:
#
#   LANG=en_US.UTF-8 RUBYOPT="-Eutf-8" ruby scripts/add_source_files.rb \
#     Halo/Core/Scanner/DriveSpeedTester.swift Halo/Features/Files/DriveSpeedView.swift
#
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Halo.xcodeproj', __dir__)
APP_TARGET   = 'Halo'

files = ARGV
abort 'Pass at least one file path (repo-relative).' if files.empty?

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == APP_TARGET }
abort "Target '#{APP_TARGET}' not found" unless target

# Index existing source file basenames on the target to stay idempotent.
existing = target.source_build_phase.files.filter_map do |bf|
  ref = bf.file_ref
  next nil unless ref.respond_to?(:path) && ref.path
  File.basename(ref.path.to_s)
rescue StandardError
  nil
end

files.each do |rel|
  abspath = File.expand_path(File.join('..', rel), __dir__)
  unless File.exist?(abspath)
    warn "  ! missing on disk: #{rel}"
    next
  end
  if existing.include?(File.basename(rel))
    puts "  = already in target: #{rel}"
    next
  end

  # Resolve or create the group matching the file's directory.
  group = project.main_group
  File.dirname(rel).split('/').each do |seg|
    group = group[seg] || group.new_group(seg, seg)
  end
  ref = group.new_reference(File.basename(rel))
  target.add_file_references([ref])
  puts "  + added to #{APP_TARGET}: #{rel}"
end

project.save
puts 'Saved.'
