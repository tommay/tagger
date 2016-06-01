#!/usr/bin/env ruby

require "bundler/setup"
require "gtk3"
require "byebug"

require_relative "model"

class Viewer
  SUFFIXES = [%r{.jpg$}i, %r{.png$}i]

  def initialize(filename)
    case
    when File.directory?(filename)
      @filenames = filter_by_suffix(Dir["#{filename}/*"])
      @nfile = 0
    when File.exist?(filename)
      dirname = File.dirname(filename)
      @filenames = filter_by_suffix(Dir["#{dirname}/*"])
      @nfile = @filenames.find_index(filename)
    else
      puts "#{filename} not found"
      exit(1)
    end

    init_ui

    set_file(@filenames[@nfile])
  end

  def filter_by_suffix(filenames)
    filenames.select do |filename|
      SUFFIXES.any? do |suffix|
        filename =~ suffix
      end
    end
  end

  def init_ui
    builder = Gtk::Builder.new
    builder.add_from_file("viewer.ui")

    @image = builder["image"]

    window = builder.get_object("the_window")

    window.signal_connect("key_press_event") do |widget, event|
      # Gdk::Keyval.to_name(event.keyval)
      case event.keyval
      when Gdk::Keyval::KEY_Left
        xnext(-1)
      when Gdk::Keyval::KEY_Right
        xnext(1)
      end
    end

    window.signal_connect("destroy") do
      Gtk.main_quit
    end

    window.show_all
  end

  def set_file(filename)
    @filename = filename
    show_filename
    show_image
  end

  def xnext(delta)
    if @filenames.size > 0
      @nfile = (@nfile + delta) % @filenames.size
    end
    set_file(@filenames[@nfile])
  end

  def show_filename
    if @filename_label
      @filename_label.set_text(@filename)
    end
  end

  def show_image
    if @filename
      pixbuf = Gdk::Pixbuf.new(file: @filename)
      image_width = @image.allocated_width
      image_height = @image.allocated_height
      pixbuf_width = pixbuf.width
      pixbuf_height = pixbuf.height
      width_ratio = image_width.to_f / pixbuf_width
      height_ratio = image_height.to_f / pixbuf_height
      ratio = width_ratio < height_ratio ? width_ratio : height_ratio
      scaled = pixbuf.scale(pixbuf_width * ratio, pixbuf_height * ratio)
      @image.set_pixbuf(scaled)
    else
      @image.set_pixbuf(nil)
    end
  end
end

Viewer.new(ARGV[0] || ".")
Gtk.main
