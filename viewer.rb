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

    load_photo(@filenames[@nfile])
  end

  def filter_by_suffix(filenames)
    filenames.select do |filename|
      SUFFIXES.any? do |suffix|
        filename =~ suffix
      end
    end
  end

  # The tag TreeViews are all nearly the same, so create them here.
  #
  def create_treeview(name)
    tags_list = Gtk::ListStore.new(String)
    tags_view = Gtk::TreeView.new(tags_list).tap do |o|
      o.headers_visible = false
      o.enable_search = false
      o.selection.mode = Gtk::SelectionMode::NONE
      renderer = Gtk::CellRendererText.new
      # Fixed text property:
      # renderer.set_text("blah")
      # renderer.set_property("text", "blah")
      column = Gtk::TreeViewColumn.new("Applied tags", renderer).tap do |o|
        # Get text from column 0 of the model:
        o.add_attribute(renderer, "text", 0)
        # Use a block to set/unset dynamically computed properties on
        # the renderer:
        # o.set_cell_data_func(renderer) do |tree_view_column, renderer, model, iter|
        #  renderer.set_text("wow")
        #  end
      end
      o.append_column(column)
    end
    [tags_list, tags_view]
  end

  def init_ui
    # Create the widgets we actually care about and save in instance
    # variables and use.  Then lay them out.

    @applied_tags_list, @applied_tags = create_treeview("Applied tags")
    @applied_tags.headers_visible = true

    @available_tags_list, @available_tags = create_treeview("Available tags")
    @directory_tags_list, @directory_tags = create_treeview("Directory tags")

    @tag_entry = Gtk::Entry.new.tap do |o|
      @tag_completion = Gtk::EntryCompletion.new.tap do |o|
        o.model = @available_tags_list
        o.text_column = 0
        o.inline_completion = true
        o.popup_completion = true
        o.popup_single_match = false
      end
      o.completion = @tag_completion
    end

    # XXX what I want is to click on a completion in the popup to set the tag,
    # but iter isn't working here.

    #@tag_completion.signal_connect("match-selected") do |widget, model, iter|
    #  puts "Got #{iter[0]}"
    #  false
    #end

    @image = Gtk::Image.new

    # Widget layout.  The tag TreeViews get wrapped in ScrolledWindows
    # and put into a Paned.  @tag_entry goes into a Box with
    # @available_tags and the Box goes in the lower pane.

    # "Often, it is useful to put each child inside a Gtk::Frame with
    # the shadow type set to Gtk::SHADOW_IN so that the gutter appears
    # as a ridge."

    paned = Gtk::Paned.new(:vertical)

    scrolled = Gtk::ScrolledWindow.new.tap do |o|
      o.hscrollbar_policy = :never
      o.vscrollbar_policy = :automatic
      # I want the scrollbars on whenever the window has enough content.
      o.overlay_scrolling = false
    end
    scrolled.add(@applied_tags)
    paned.pack1(scrolled, resize: true, shrink: false)

    # Make the available tags treeviews scrollable, and put them in a notebook
    # with a page for each type (all, directory, etc.).

    notebook = Gtk::Notebook.new.tap do |o|
      # Allow scrolling if there are too many tabs.
      o.scrollable = true
    end

    [["Dir", @directory_tags], ["All", @available_tags]].each do |name, treeview|
      scrolled = Gtk::ScrolledWindow.new.tap do |o|
        o.hscrollbar_policy = :never
        o.vscrollbar_policy = :automatic
        o.overlay_scrolling = false
        #o.shadow_type(:etched_out)
      end
      scrolled.add(treeview)

      label = Gtk::Label.new(name)
      notebook.append_page(scrolled, label)
    end

    # Box up @tag_entry and notebook.

    box = Gtk::Box.new(:vertical)
    box.pack_start(@tag_entry, expand: false)
    box.pack_start(notebook, expand: true, fill: true)
    paned.pack2(box, resize: true, shrink: false)
    #paned.position = ??

    box = Gtk::Box.new(:horizontal)
    box.pack_start(paned, expand: false)

    # Put @image into an event box so it can get mouse clicks and
    # drags.

    @image.set_size_request(400, 400)
    event_box = Gtk::EventBox.new
    event_box.add(@image)
    box.pack_start(event_box, expand: true, fill: true)
#    event_box.signal_connect("button_press_event") do
#      puts "Clicked."
#    end

    # Finally, the top-level window.

    window = Gtk::Window.new.tap do |o|
      o.title = "Viewer"
      # o.override_background_color(:normal, Gdk::RGBA::new(0.2, 0.2, 0.2, 1))
      o.set_default_size(300, 280)
      o.position = :center
    end
    window.add(box)

    @tag_entry.signal_connect("activate") do |widget|
      tag = widget.text.strip
      widget.set_text("")
      if tag != ""
        add_tag(tag)
      end
    end

    @applied_tags.signal_connect("row-activated") do |widget, path, column|
      tag = widget.model.get_iter(path)[0]
      remove_tag(tag)
    end

    @available_tags.signal_connect("row-activated") do |widget, path, column|
      tag = widget.model.get_iter(path)[0]
      add_tag(tag)
    end

    load_available_tags

    window.signal_connect("key_press_event") do |widget, event|
      # Gdk::Keyval.to_name(event.keyval)
      case event.keyval
      when Gdk::Keyval::KEY_Left
        prev_photo
      when Gdk::Keyval::KEY_Right
        next_photo
      end
      false
    end

    window.signal_connect("destroy") do
      Gtk.main_quit
    end

    window.show_all
  end

  def load_photo(filename)
    @photo = filename && Photo.find_or_create(filename)
    load_applied_tags
    load_directory_tags
    show_filename
    show_image
  end

  def next_photo(delta = 1)
    if @filenames.size > 0
      @nfile = (@nfile + delta) % @filenames.size
    end
    load_photo(@filenames[@nfile])
  end

  def prev_photo
    next_photo(-1)
  end

  def show_filename
    if @filename_label
      @filename_label.set_text(@photo && @photo.filename)
    end
  end

  def show_image
    if @photo
      pixbuf = Gdk::Pixbuf.new(file: @photo.filename)
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

  def add_tag(string)
    # XXX I think this is supposed to work, but it only works if the tag
    # doesn't exist in which case it creates the tag and links it, else
    # it does nothing.
    # @photo.tags.first_or_create(tag: string)
    # So do it the hard way.
    tag = Tag.first_or_create(tag: string)
    if !@photo.tags.include?(tag)
      @photo.tags << tag
      @photo.save
      load_applied_tags
      load_available_tags
      load_directory_tags
    end
  end

  def remove_tag(string)
    tag = @photo.tags.first(tag: string)
    @photo.tags.delete(tag)
    @photo.save
    load_applied_tags
    load_directory_tags
  end

  def load_applied_tags
    @applied_tags_list.clear
    @photo.tags.each do |tag|
      @applied_tags_list.append[0] = tag.tag
    end
  end

  def load_available_tags
    @available_tags_list.clear
    Tag.all.each do |tag|
      @available_tags_list.append[0] = tag.tag
    end
  end

  def load_directory_tags
    @directory_tags_list.clear
    if @photo
      Photo.all(directory: @photo.directory).tags.each do |tag|
        @directory_tags_list.append[0] = tag.tag
      end
    end
  end
end

Viewer.new(ARGV[0] || ".")
Gtk.main
