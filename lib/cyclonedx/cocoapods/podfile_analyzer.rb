# frozen_string_literal: true
#
# This file is part of CycloneDX CocoaPods
#
# Licensed under the Apache License, Version 2.0 (the “License”);
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an “AS IS” BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) OWASP Foundation. All Rights Reserved.
#

require 'cocoapods'
require 'logger'

require_relative 'pod'
require_relative 'pod_attributes'
require_relative 'source'

module CycloneDX
  module CocoaPods
    class PodfileParsingError < StandardError; end

    class PodfileAnalyzer
      def initialize(logger:)
        @logger = logger
      end

      def ensure_podfile_and_lock_are_present(options)
        project_dir = Pathname.new(options[:path] || Dir.pwd)
        raise PodfileParsingError, "#{options[:path]} is not a valid directory." unless File.directory?(project_dir)
        options[:podfile_path] = project_dir + 'Podfile'
        raise PodfileParsingError, "Missing Podfile in #{project_dir}. Please use the --path option if not running from the CocoaPods project directory." unless File.exist?(options[:podfile_path])
        options[:podfile_lock_path] = project_dir + 'Podfile.lock'
        raise PodfileParsingError, "Missing Podfile.lock, please run 'pod install' before generating BOM" unless File.exist?(options[:podfile_lock_path])

        initialize_cocoapods_config(project_dir)

        lockfile = ::Pod::Lockfile.from_file(options[:podfile_lock_path])
        verify_synced_sandbox(lockfile)

        return ::Pod::Podfile.from_file(options[:podfile_path]), lockfile
      end


      def parse_pods(podfile, lockfile)
        @logger.debug "Parsing pods from #{podfile.defined_in_file}"
        return lockfile.pod_names.map do |name|
          Pod.new(name: name, version: lockfile.version(name), source: source_for_pod(podfile, lockfile, name), checksum: lockfile.checksum(name))
        end
      end


      def populate_pods_with_additional_info(pods)
        pods.each do |pod|
          @logger.debug "Completing information for #{pod.name}"
          pod.complete_information_from_source
        end
        return pods
      end


      private


      def initialize_cocoapods_config(project_dir)
        ::Pod::Config.instance.installation_root = project_dir
      end


      def verify_synced_sandbox(lockfile)
        manifestFile = ::Pod::Config.instance.sandbox.manifest
        raise PodfileParsingError, "Missing Manifest.lock, please run 'pod install' before generating BOM" if manifestFile.nil?
        raise PodfileParsingError, "The sandbox is not in sync with the Podfile.lock. Run 'pod install' or update your CocoaPods installation." unless lockfile == manifestFile
      end


      def cocoapods_repository_source(podfile, lockfile, pod_name)
        @source_manager ||= create_source_manager(podfile)
        return Source::CocoaPodsRepository.searchable_source(url: lockfile.spec_repo(pod_name), source_manager: @source_manager)
      end


      def git_source(lockfile, pod_name)
        checkout_options = lockfile.checkout_options_for_pod_named(pod_name)
        url = checkout_options[:git]
        [:tag, :branch, :commit].each do |type|
          return Source::GitRepository.new(url: url, type: type, label: checkout_options[type]) if checkout_options[type]
        end
        return Source::GitRepository.new(url: url)
      end


      def source_for_pod(podfile, lockfile, pod_name)
        root_name = pod_name.split('/').first
        return cocoapods_repository_source(podfile, lockfile, root_name) unless lockfile.spec_repo(root_name).nil?
        return git_source(lockfile, root_name) unless lockfile.checkout_options_for_pod_named(root_name).nil?
        return Source::LocalPod.new(path: lockfile.to_hash['EXTERNAL SOURCES'][root_name][:path]) if lockfile.to_hash['EXTERNAL SOURCES'][root_name][:path]
        return Source::Podspec.new(url: lockfile.to_hash['EXTERNAL SOURCES'][root_name][:podspec]) if lockfile.to_hash['EXTERNAL SOURCES'][root_name][:podspec]
        return nil
      end


      def create_source_manager(podfile)
        sourceManager = ::Pod::Source::Manager.new(::Pod::Config::instance.repos_dir)
        @logger.debug "Parsing sources from #{podfile.defined_in_file}"
        podfile.sources.each do |source|
          @logger.debug "Ensuring #{source} is available for searches"
          sourceManager.find_or_create_source_with_url(source)
        end
        @logger.debug "Source manager successfully created with all needed sources"
        return sourceManager
      end
    end
  end
end
