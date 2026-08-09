#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds firebase-ios-sdk (FirebaseDatabase + FirebaseAuth) as an SPM dependency
# of the Halo target — the F-044 Phase 0 spike. RTDB+Auth are chosen over
# Firestore partly because they pull much lighter deps (no gRPC/abseil).
# Idempotent.
#
#   LANG=en_US.UTF-8 RUBYOPT="-Eutf-8" ruby scripts/add_firebase_package.rb
#
require 'xcodeproj'

PROJECT = File.expand_path('../Halo.xcodeproj', __dir__)
URL = 'https://github.com/firebase/firebase-ios-sdk.git'
PRODUCTS = %w[FirebaseDatabase FirebaseAuth]

project = Xcodeproj::Project.open(PROJECT)
target = project.targets.find { |t| t.name == 'Halo' }
raise 'Halo target not found' unless target

# Idempotency: drop existing firebase package ref + its product deps.
project.root_object.package_references.dup.each do |pkg|
  next unless pkg.respond_to?(:repositoryURL) && pkg.repositoryURL == URL
  project.root_object.package_references.delete(pkg)
end
target.package_product_dependencies.dup.each do |dep|
  target.package_product_dependencies.delete(dep) if PRODUCTS.include?(dep.product_name)
end
target.frameworks_build_phase.files.dup.each do |bf|
  pr = bf.product_ref
  target.frameworks_build_phase.remove_build_file(bf) if pr && PRODUCTS.include?(pr.product_name)
end

# Add the remote package reference.
pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
pkg.repositoryURL = URL
pkg.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '11.0.0' }
project.root_object.package_references << pkg

# Add product dependencies + link them.
PRODUCTS.each do |name|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = name
  target.package_product_dependencies << dep

  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  target.frameworks_build_phase.files << bf
  puts "  + linked #{name}"
end

project.save
puts 'Saved. firebase-ios-sdk (Database + Auth) added to the Halo target.'
