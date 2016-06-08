#!/usr/bin/env ruby

require "bundler/setup"
require "optparse"
require "byebug"
require_relative "../model"
require_relative "../files"
require_relative "../xmp"

# export *.jpg
#   If there's a matching image file by name, then export its tags
#   to an xmp sidecar file, adding to any existing tags (?).

OptionParser.new do |opts|
  opts.banner = "Usage: $0 [options] [directory...]"

  opts.on("-h", "--help", "Print this help") do
    puts opts
    exit
  end
end.parse!

def export(filename, options, top)
  case
  when (top || options[:recurse]) && File.directory?(filename)
    Dir[File.join(filename, "*")].each do |f|
      export(f, options, false)
    end
  when Files.image_file?(filename)
    export_to_sidecar(filename)
  end
end

def export_to_sidecar(filename)
  # Find a database entry if we have one.  If we don't, there is
  # nothing to export.

  photo = Photo.find(filename)
  if !photo
    return
  end

  # Load a sidecar file if one exists.  Otherwise, start with a
  # minimal document that sets up the proper elements and namespaces.

  xmp_filename = filename + ".xmp"
  xmp =
    begin
      Xmp.new(File.read(xmp_filename))
    rescue Errno::ENOENT
      Xmp.minimal
    end

  # Add the photo's tags.

  photo.tags.each do |tag|
    xmp.add_tag(tag.tag)
  end

  # Make a backup of the original xmp and save the new one.

  begin
    File.rename(xmp_filename, xmp_filename + ".0")
  rescue Errno::ENOENT
  end
  File.write(xmp_filename, xmp.to_s)
end

ARGV.each do |filename|
  export_to_sidecar(filename)
end