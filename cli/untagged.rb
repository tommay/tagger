#!/usr/bin/env ruby

require "bundler/setup"
require "trollop"
require "byebug"
require_relative "helpers"
require_relative "../importer"

options = Trollop::options do
  banner "Usage: #{$0} [options] file|directory..."
  opt :directories, "List directories with untagged files"
  opt :recurse, "Recurse into directories"
end

directories = {}

process_args(ARGV, options.recurse) do |filename|
  if Photo.find_dataset(filename).phototags.count == 0
    if options.directories
      directory = File.dirname(filename)
      if !directories[directory]
        directories[directory] = true
        puts directory
      end
    else
      puts filename
    end
  end
end
