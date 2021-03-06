#!/usr/bin/env ruby

require "pathname"
ENV["BUNDLE_GEMFILE"] = Pathname.new(__FILE__).realpath.dirname.join("Gemfile").to_s

require "bundler/setup"
require "set"
require "gtk3"
require "fileutils"
require "byebug"

require_relative "model"
require_relative "photo_window"
require_relative "files"
require_relative "importer"
require_relative "exporter"
require_relative "save_list"
require_relative "entry_dialog"
require_relative "restore"

class Tagger
  def initialize(args)
    GC.start
    init_ui

    #STDIN.reopen("/dev/null")
#    byebug

    @recent = SaveList.new([])
    @history = Rotator.new

    @recent_tags_hash = {}

    @mark = nil

    # This will skip initial arguments that don't exist.

    args = (!args.empty? ? args : ["."]).map do |arg|
      Pathname.new(arg).realpath.to_s rescue nil
    end.compact
    @args = Rotator.new(args)
    @args.forwards
    next_arg

    @get_next = get_next_in_directory
  end

  def init_ui
    # Create the widgets we actually care about and save in instance
    # variables for use.  Then lay them out.

    @rating = Gtk::Label.new

    # Applied tags aren't sorted.  It's more intuitive to leave them
    # in the order they're added at first.  XXX might want to add a column
    # to photo_tags for this.

    @applied_tags = create_treeview("Applied tags", sorted: false)
    #applied_tags.headers_visible = true

    @available_tags = create_treeview("Available tags")
    @directory_tags = create_treeview("Directory tags")
    @recent_tags = create_treeview("Recent tags", sorted: false)

    # Searching a Gtk::ListStore is noticeably slow, especially if the
    # item isn't found or is near the end of the list.  So maintain an
    # auxiliary set of the tags in the list for fast determination of
    # whether a tag is already in the list.

    @available_tags_set = Set.new

    @tag_entry = Gtk::Entry.new.tap do |o|
      # The completion list intentionally uses all tags, instead of
      # using the list selected in the notebook tab.  This seems more
      # useful.  Time will tell.
      tag_completion = Gtk::EntryCompletion.new.tap do |o|
        o.model = @available_tags.model
        o.text_column = 0
        o.inline_completion = true
        o.popup_completion = true
        o.popup_single_match = false
      end
      o.completion = tag_completion

      # XXX what I want is to click on a completion in the popup to
      # set the tag, but iter is null here.

      #tag_completion.signal_connect("match-selected") do |widget, model, iter|
      #  puts "Got #{iter[0]}"
      #end
    end

    @photo_window = PhotoWindow.new

    # Widget layout.  The tag TreeViews get wrapped in
    # ScrolledWindows.  There are two panes, upper and lower, whose
    # boundary can be dragged up and down.  The upper pane gets a box
    # containing @rating, applied_tags, and @textentry.  The lower
    # pane gets a notebook containing directory_tags and
    # available_tags.

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

    # Box up @rating, applied_tags's ScrollWindow, and @tag_entry.

    box = Gtk::Box.new(:vertical)
    box.pack_start(@rating, expand: false)
    box.pack_start(scrolled, expand: true, fill: true)
    box.pack_start(@tag_entry, expand: false)

    # Put the box in the upper pane.

    paned.pack1(box, resize: true, shrink: false)

    # Make the available tags treeviews scrollable, and put them in a notebook
    # with a page for each type (all, directory, etc.).

    notebook = Gtk::Notebook.new.tap do |o|
      # Allow scrolling if there are too many tabs.
      o.scrollable = true
    end

    [["Dir", @directory_tags],
     ["Rec", @recent_tags],
     ["All", @available_tags]].each do |name, treeview|
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

    # Put the notebook in the lower pane.

    paned.pack2(notebook, resize: true, shrink: false)
    #paned.position = ??

    # The Paned and the PhotoWindow go left and right.

    box = Gtk::Box.new(:horizontal)
    box.pack_start(paned, expand: false)
    box.pack_start(@photo_window.get_widget, expand: true, fill: true)

    # Finally, put the box in the top-level window.

    @window = Gtk::Window.new.tap do |o|
      o.title = "Tagger"
      # o.override_background_color(:normal, Gdk::RGBA::new(0.2, 0.2, 0.2, 1))
      o.set_default_size(300, 280)
      o.position = :center
    end
    @window.add(box)

    @tag_entry.signal_connect("activate") do |widget|
      tag = widget.text.strip
      widget.set_text("")
      if tag != ""
        add_tag(tag)
      end
    end

    @applied_tags.signal_connect("button-release-event") do |widget, event|
      if event.state == Gdk::ModifierType::BUTTON1_MASK
#        byebug
#        tag = widget.model.get_iter(path)[0]
#        puts "Clicked."
      end
    end

    @applied_tags.signal_connect("row-activated") do |widget, path, column|
      tag = widget.model.get_iter(path)[0]
      remove_tag(tag)
    end

    [@available_tags, @directory_tags, @recent_tags].each do |tags_view|
      tags_view.signal_connect("row-activated") do |widget, path, column|
        tag = widget.model.get_iter(path)[0]
        add_tag(tag)
      end
    end

    # When we start typing with the focus on one of the treeviews,
    # move the focus to the @tag_entry instead of making the user do
    # it manually after realizing @tag_entry isn't focused.

    [@applied_tags, @available_tags, @directory_tags, @recent_tags].each do
      |treeview|
      treeview.signal_connect("key-press-event") do |widget, event|
        if event.string >= "a" && event.string <= "z"
          @tag_entry.grab_focus
          @tag_entry.event(event)
        end
        false
      end
    end

    load_available_tags

    @window.signal_connect("key-press-event") do |widget, event|
      # puts Gdk::Keyval.to_name(event.keyval)
      case event.keyval
      when Gdk::Keyval::KEY_Left
        prev_in_directory
        true
      when Gdk::Keyval::KEY_Right
        next_in_directory
        true
      when Gdk::Keyval::KEY_Up
        prev_arg
        true
      when Gdk::Keyval::KEY_Down
        next_arg
        true
      when Gdk::Keyval::KEY_b
        if event.state == Gdk::ModifierType::CONTROL_MASK
          @history.backwards&.tap do |filename|
            load_photo(filename)
          end
          true
        end
      when Gdk::Keyval::KEY_f
        if event.state == Gdk::ModifierType::CONTROL_MASK
          @history.forwards&.tap do |filename|
            load_photo(filename)
          end
          true
        end
      when Gdk::Keyval::KEY_l
        if @photo && !tagging?
          case event.state
          when Gdk::ModifierType::CONTROL_MASK
            @photo.lock
            true
          when Gdk::ModifierType::MOD1_MASK
            @photo.unlock
            true
          end
        end
      when Gdk::Keyval::KEY_Delete
        if @photo && 
           (!@photo.locked? || question_dialog("Deleted locked photo?"))
          # When working in .deleted directories, always move to the next file.
          if @photo.deleted?
            @get_next = get_next_in_directory
          end
          next_filename = @get_next.call(:next, @photo.filename)
          if next_filename == @photo.filename
            next_filename = nil
          end
          old_filename = @photo.filename
          @restore = delete_photo(@photo)
          if @mark == old_filename
            @mark = nil
          end
          load_photo(next_filename)
        end
        true
      when Gdk::Keyval::KEY_d
        if event.state == Gdk::ModifierType::CONTROL_MASK
          switch_to_from_deleted_directory
          true
        end
      when Gdk::Keyval::KEY_z
        if event.state == Gdk::ModifierType::CONTROL_MASK
          if @restore
            @restore.call
            @restore = nil
          end
          true
        end
      when Gdk::Keyval::KEY_v
        if event.state == Gdk::ModifierType::CONTROL_MASK
          @photo && rename_directory_dialog
          true
        end
      when Gdk::Keyval::KEY_n
        if event.state == Gdk::ModifierType::CONTROL_MASK
          next_directory
          true
        end
      when Gdk::Keyval::KEY_p
        if event.state == Gdk::ModifierType::CONTROL_MASK
          prev_directory
          true
        end
      when Gdk::Keyval::KEY_space
        if event.state == Gdk::ModifierType::CONTROL_MASK
          @photo && @mark = @photo.filename
          true
        end
      when Gdk::Keyval::KEY_x
        case event.state
        when Gdk::ModifierType::CONTROL_MASK
          if @mark && @photo
            mark = @mark
            @mark = @photo.filename
            load_photo(mark)
          end
          true
        when Gdk::ModifierType::MOD1_MASK
          if @mark
            load_photo(@mark)
          end
          true
        end
      when Gdk::Keyval::KEY_6
        if event.state == Gdk::ModifierType::CONTROL_MASK
          crop_6mm
          true
        end
      when Gdk::Keyval::KEY_s
        if event.state == Gdk::ModifierType::CONTROL_MASK
          save_last
          true
        end
      when Gdk::Keyval::KEY_r
        if event.state == Gdk::ModifierType::CONTROL_MASK
          restore_last
          true
        end
      when Gdk::Keyval::KEY_u
        case event.state
        when Gdk::ModifierType::CONTROL_MASK
          # Move to the next untagged photo.
          next_in_directory do |filename|
            photo = import_photo(filename)
            photo.tags.empty?
          end
          true
        when Gdk::ModifierType::MOD1_MASK
          # Move to the next unrated photo.
          next_in_directory do |filename|
            photo = import_photo(filename)
            photo.rating.nil?
          end
          true
        end
      when Gdk::Keyval::KEY_m
        # C-m: ask where to move the photo
        # A-m: just move it to the last directory, but with date adjusted
        if @photo
          case event.state
          when Gdk::ModifierType::CONTROL_MASK
            move_photo_dialog(ask: true)
            true
          when Gdk::ModifierType::MOD1_MASK
            move_photo_dialog(ask: false)
            true
          end
        end
      when Gdk::Keyval::KEY_e
        if event.state == Gdk::ModifierType::CONTROL_MASK
          @photo && Exporter.export_photo_to_sidecar(@photo, merge: false)
          true
        end
      when Gdk::Keyval::KEY_c
        if event.state == Gdk::ModifierType::CONTROL_MASK
          @photo && Gtk::Clipboard.get(Gdk::Selection::CLIPBOARD).tap do |c|
            c.set_text(@photo.filename)
            c.store
          end
          true
        end
      when Gdk::Keyval::KEY_w
        if event.state == Gdk::ModifierType::CONTROL_MASK
          @photo && Gtk::Clipboard.get(Gdk::Selection::CLIPBOARD).tap do |c|
            filename = @photo.filename
                       .sub(%r{^.*/host/}, "c:/users/tom/")
                       .sub(%r{^/home/tom/D/}, "c:/users/tom/Desktop/")
                       .sub(%r{^/home/tom/N/}, "n:/")
                       .gsub(%r{/}, "\\")
            c.set_text(filename)
            c.store
          end
          true
        end
      when Gdk::Keyval::KEY_comma
        if event.state == Gdk::ModifierType::CONTROL_MASK
          rotate_left
        else
          use_recent_tags(:older)
        end
        true
      when Gdk::Keyval::KEY_period
        if event.state == Gdk::ModifierType::CONTROL_MASK
          rotate_right
        else
          use_recent_tags(:newer)
        end
        true
      when Gdk::Keyval::KEY_9
        if !tagging?
          @photo_window.set_scale(1)
          true
        else
          false
        end
      when Gdk::Keyval::KEY_0
        case event.state
        when Gdk::ModifierType::CONTROL_MASK
          load_photo(@directory)
          true
        else
          if !tagging?
            @photo_window.set_scale(:fit)
            true
          end
        end
      when Gdk::Keyval::KEY_1 .. Gdk::Keyval::KEY_5
        if @photo && !tagging?
          rate_photo(@photo, event.keyval - Gdk::Keyval::KEY_0)
          if event.state != Gdk::ModifierType::CONTROL_MASK
            # Move to the next unrated photo, for quickly rating photos.
            next_photo do |filename|
              if File.directory?(filename)
                # The next filename is a directory, e.g., we're moving
                # through the argument list.  Just stop there.
                true
              else
                photo = import_photo(filename)
                !photo.rating
              end
            end
          else
            # Stay on the current photo, just show the new rating.
            show_rating
          end
          true
        else
          false
        end
      when Gdk::Keyval::KEY_minus
        if @photo && !tagging?
          rate_photo(@photo, nil)
          show_rating
          true
        end
      end
    end

    @window.signal_connect("destroy") do
      save_last
      Gtk.main_quit
    end

    #@window.maximize
    @window.show_all
  end

  def tagging?
    @tag_entry.has_focus? && @tag_entry.text != ""
  end

  def rate_photo(photo, rating)
    @restore = Restore.new(photo, photo.rating) do |photo, rating|
      photo.set_rating(rating)
      load_photo(photo.filename)
    end
    photo.set_rating(rating)
  end

  # The tag TreeViews are all nearly the same, so create them here.
  #
  def create_treeview(name, sorted: true)
    tags_list = Gtk::ListStore.new(String).tap do |o|
      if sorted
        o.set_sort_column_id(0, Gtk::SortType::ASCENDING)
      end
    end
    Gtk::TreeView.new(tags_list).tap do |o|
      o.headers_visible = false
      o.enable_search = false
      o.selection.mode = Gtk::SelectionMode::NONE
      o.activate_on_single_click = true
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
  end

  def load_photo(filename)
    if @photo
      save_recent_tags
    end
    if filename && File.directory?(filename)
      # Set @directory in case there is nothing to load into @photo.
      @directory = filename
      filename = Files.for_directory(filename).first
    end
    @photo = filename && import_photo(filename)
    if @photo
      @directory = @photo.directory
      save_history
    end
    load_applied_tags
    load_directory_tags
    show_filename
    show_rating
    show_photo
  end

  def import_photo(filename)
    Importer.find_or_import_from_file(
      filename, copy_tags_and_rating: true,
      purge_identical_images: true)
  end

  def save_recent_tags
    tags = @photo.tags.map do |t|
      t.tag
    end
    @recent.add(tags)
  end

  def use_recent_tags(older_or_newer)
    if @photo
      current_tags = @photo.tags.map {|t| t.tag}
      new_tags = @recent.send(older_or_newer, current_tags)
      Photo.db.transaction do
        (current_tags - new_tags).each do |tag|
          @photo.remove_tag(tag)
        end
        (new_tags - current_tags).each do |tag|
          @photo.add_tag(tag)
          add_recent_tag(tag)
        end
      end
      load_applied_tags
      load_recent_tags
    end
  end

  def save_history
    @history.add(@photo.filename)
  end

  def next_photo(&block)
    if @photo
      next_filename = @get_next.call(:next, @photo.filename, &block)
      load_photo(next_filename)
    end
  end

  def next_in_directory(dir = :next, filename = @photo&.filename, &block)
    if @photo
      @get_next = get_next_in_directory
      filename = @get_next.call(dir, filename, &block)
      load_photo(filename)
    end
  end

  def prev_in_directory
    next_in_directory(:prev)
  end

  def get_next_in_directory
    lambda do |dir, filename, &block|
      delta = (dir == :next) ? 1 : -1
      files = Files.for_directory(File.dirname(filename))
      initial = files.index(filename)
      n = initial
      begin
        n = (n + delta) % files.size
      end until n == initial || !block || block.call(files[n])
      files[n]
    end
  end

  def next_directory(delta = 1)
    parent = File.dirname(@directory)
    siblings = Dir[File.join(parent, "*")].select{|x| File.directory?(x)}.sort
    index = siblings.index(@directory)
    if index
      index += delta
      if index >= 0 && index < siblings.size
        load_photo(siblings[index])
      end
    end
  end

  def prev_directory
    next_directory(-1)
  end

  def next_arg(dir = :next)
    @get_next = get_next_arg
    filename = @get_next.call(dir)
    load_photo(filename)
  end

  def prev_arg
    next_arg(:prev)
  end

  def get_next_arg
    lambda do |dir, _filename = nil, &block|
      method = (dir == :next) ? :backwards : :forwards
      initial = @args.current
      begin
        arg = @args.send(method)
      end until arg == initial ||
                (arg && File.exist?(arg) && (!block || block.call(arg)))
      if arg && File.exist?(arg)
        arg
      end
    end
  end

  def show_filename
    info = @photo && info_string(@photo)
    @window.title = "Tagger: #{@photo ? @photo.filename : @directory}#{info ? " - #{info}" : ""}"
  end

  def info_string(photo)
    date_string = photo.date_string
    if date_string
      date_string += " - "
    end
    focal_length =
      if photo.focal_length
        photo.focal_length.to_i.to_s + "mm"
      end
    focal_length_35mm =
      if photo.focal_length_35mm
        "(" + photo.focal_length_35mm.to_i.to_s + "mm)"
      end
    aperture =
      if photo.aperture
        f = numeric_string(photo.aperture)
        "f/#{f}"
      end
    exposure =
      if photo.exposure_time
        e = photo.exposure_time
        if e < 1
          s = numeric_string(1.0/e)
          "1/#{s}"
        else
          numeric_string(e)
        end
      end
    info = [date_string, focal_length, focal_length_35mm, aperture, exposure,
            photo.camera_make, photo.camera_model].compact
    if info.size > 0
      info.join(" ")
    end
  end

  def numeric_string(float)
    s = "%.1f" % float
    s.sub(/\.0*$/, "")
  end

  def show_rating
    @rating.set_text(@photo && @photo.rating ? "*" * @photo.rating : "")
  end

  def show_photo
    @photo_window.show_photo(@photo&.filename)
  end

  def add_tag(string)
    if @photo&.add_tag(string)
      load_applied_tags
      add_available_tag(string)
      load_directory_tags
      add_recent_tag(string)
      load_recent_tags
    end
  end

  def remove_tag(string)
    if @photo&.remove_tag(string)
      load_applied_tags
      load_directory_tags
    end
  end

  def load_applied_tags
    list = @applied_tags.model
    list.clear
    if @photo
      @photo.tags.each do |tag|
        list.append[0] = tag.tag
      end
    end
  end

  def load_available_tags
    list = @available_tags.model
    # Disable sorting while the list is loaded.
    sort_column_id = list.sort_column_id[1,2]
    begin
      #list.set_sort_column_id(-1, :ascending)
      #list.set_default_sort_func{-1}
      list.clear
      Tag.each do |tag|
        list.append[0] = tag.tag
        @available_tags_set << tag.tag
      end
    ensure
      #list.set_sort_column_id(*sort_column_id)
    end
  end

  def add_available_tag(tag)
    if !@available_tags_set.include?(tag)
      @available_tags.model.append[0] = tag
      @available_tags_set << tag
    end
  end

  def load_directory_tags
    list = @directory_tags.model
    list.clear
    # This is crap.  This is what we want here:
    #   Photo.where(directory: @directory).tags.each do |tag|
    # But Sequel selects the ids of all the Photos in the directory,
    # then creates a giant WHERE clause using OR that sqlite blows up
    # on.  So much for the dataset_associations plugin.  So roll our
    # own join.
    # 
    # select * from tags
    #   join photos_tags
    #     on photos_tags.tag_id = tags.id
    #   join photos
    #     on photos.id = photos_tags.photo_id
    #   where photos.directory = ?;
    #
    # explain query plan:
    # 0|0|2|SEARCH TABLE photos USING INDEX sqlite_autoindex_photos_1 (directory=?)
    # 0|1|1|SEARCH TABLE photos_tags USING COVERING INDEX sqlite_autoindex_photos_tags_1 (photo_id=?)
    # 0|2|0|SEARCH TABLE tags USING INTEGER PRIMARY KEY (rowid=?)
    #
    # But it's more straightforward with subqueries:
    # explain query plan:
    # select * from tags
    #   where tags.id  in (
    #     select photos_tags.tag_id from photos_tags
    #       where photos_tags.photo_id in (
    #         select photos.id from photos
    #           where photos.directory = ?));
    # 0|0|0|SEARCH TABLE tags USING INTEGER PRIMARY KEY (rowid=?)
    # 0|0|0|EXECUTE LIST SUBQUERY 1
    # 1|0|0|SEARCH TABLE photos_tags USING COVERING INDEX sqlite_autoindex_photos_tags_1 (photo_id=?)
    # 1|0|0|EXECUTE LIST SUBQUERY 2
    # 2|0|0|SEARCH TABLE photos USING COVERING INDEX sqlite_autoindex_photos_1 (directory=?)

    # Now that Phototag is defined it works to chain the datasets
    # instead of building up the subqueries manually using
    # .select(...).where(...).

    Photo.where(directory: @directory).phototags.tags.each do |tag|
      list.append[0] = tag.tag
    end

    restore_scroll_when_idle(@directory_tags)
  end

  def add_recent_tag(string)
    @recent_tags_hash.delete(string)
    @recent_tags_hash[string] = true
  end

  def load_recent_tags
    list = @recent_tags.model
    list.clear
    @recent_tags_hash.keys.reverse_each do |tag|
      list.append[0] = tag
    end
  end

  def delete_photo(photo)
    # If the file isn't in a .deleted directory, then delete by
    # creating and renaming to a .deleted subdirectory.  If it's in a
    # .deleted directory, then delete by renaming/restoring to the
    # parent directory.

    dst_dirname =
      if !photo.deleted?
        create_deleted_dir(photo.directory)
      else
        File.dirname(photo.directory)
      end

    old_directory = photo.directory

    move_photo(photo, dst_dirname)

    new_filename = photo.filename

    # Restoring is just a matter of moving things back.

    Restore.new do
      photo = Photo.find(new_filename)
      move_photo(photo, old_directory)
      load_photo(photo.filename)
    end
  end

  def move_photo(photo, new_directory)
    if !File.exist?(new_directory)
      if question_dialog("Create #{new_directory}?")
        FileUtils.mkdir_p(new_directory)
      end
    end

    if File.exist?(new_directory)
      move_related_files(photo.filename, new_directory)

      photo.directory = new_directory
      photo.save
    end
  end

  def move_related_files(filename, dst_dir)
    # Move everything with the same basename regardless of suffix.

    src_dir = File.dirname(filename)
    File.basename(filename) =~ /^(.*)\./
    base = $1

    Dir[File.join(src_dir, "#{base}.*")].each do |src_name|
      dst_name = File.join(dst_dir, File.basename(src_name))
      File.rename(src_name, dst_name)
    end
  end

  def switch_to_from_deleted_directory
    if Files.deleted?(@directory)
      parent = File.dirname(@directory)
      load_photo(parent)
    else
      deleted_directory = File.join(@directory, ".deleted")
      if File.exist?(deleted_directory)
        load_photo(deleted_directory)
      end
    end
  end

  def rename_directory_dialog
    photo_date = @photo&.date_string
    EntryDialog.new(
      title: "Rename Directory", parent: @window,
      text: @directory,
      width_chars: @directory.size + 20,
      insert_text: photo_date) do |text|
      begin
        rename_photos_directory(text)
      rescue => ex
        error_dialog("#{text}: #{ex}")
      end
    end
  end

  def error_dialog(msg)
    dialog = Gtk::MessageDialog.new(
      type: Gtk::MessageType::ERROR,
      message: msg,
      buttons: :ok,
      parent: @window,
      flags: Gtk::DialogFlags::DESTROY_WITH_PARENT)
    dialog.run
    dialog.destroy
  end

  def question_dialog(question)
    dialog = Gtk::MessageDialog.new(
      type: Gtk::MessageType::QUESTION,
      message: question,
      buttons: Gtk::ButtonsType::YES_NO,
      parent: @window,
      flags: Gtk::DialogFlags::DESTROY_WITH_PARENT)
    response = dialog.run
    dialog.destroy
    response == Gtk::ResponseType::YES
  end

  def rename_photos_directory(new_directory)
    if File.exist?(new_directory)
      raise "#{new_directory} already exists"
    end
    File.rename(@directory, new_directory)

    Photo.where(directory: @directory)
      .update(directory: new_directory)

    load_photo(File.join(new_directory, @photo.basename))
  end

  def transform(*args)
    return if !@photo
    return if Files.deleted?(@directory)

    # Transform the file, and create a .bak file.

    msg = IO.popen(["/usr/bin/env"] + args, err: [:child, :out]) do |pipe|
      pipe.readlines(nil).first.chomp
    end
    if !$?.success?
      error_dialog(msg)
      return
    end

    # Update the sha1.

    @photo.set_sha1
    @photo.save

    # Move the .bak file to .deleted, where it will eventually be
    # cleaned up.  Unless there is already an existing .bak file, in
    # which case just leave it.  This allows multiple rotations to be
    # undone by restoring the original backup.

    deleted_dirname = create_deleted_dir(@photo.directory)
    bak_filename = File.join(deleted_dirname, "#{@photo.basename}.bak")
    if !File.exist?(bak_filename)
      File.rename("#{@photo.filename}.bak", bak_filename)
    end

    @restore = Restore.new(@photo.filename) do |filename, sha1|
      File.rename(bak_filename, filename)
      load_photo(filename)
      @photo.set_sha1
      @photo.save
    end

    # Show the transformed photo.

    load_photo(@photo.filename)
  end

  def crop_6mm
    # Losslessly crop and create a .bak file.

    transform("6mm", @photo.filename)
  end

  def rotate_left
    transform("jrot", "-l", @photo.filename)
  end

  def rotate_right
    transform("jrot", "-r", @photo.filename)
  end

  def create_deleted_dir(directory)
    File.join(directory, ".deleted").tap do |deleted_dirname|
      if !File.exist?(deleted_dirname)
        Dir.mkdir(deleted_dirname)
      end
    end
  end

  def move_photo_dialog(ask:)
    last =
      if @move_last_directory == @directory
        @move_last
      else
        @directory
      end
    photo_date = @photo.date_string
    if photo_date
      last = last.sub(/\d{4}-\d{2}-\d{2}/, photo_date)
    end

    block = lambda do |text|
      begin
        # When working in .deleted directories, always move to the next file.
        if @photo.deleted?
          @get_next = get_next_in_directory
        end
        next_filename = @get_next.call(:next, @photo.filename)
        if next_filename == @photo.filename
          next_filename = nil
        end
        old_filename = @photo.filename
        move_photo(@photo, text)
        if @mark == old_filename
          @mark = @photo.filename
        end
        @move_last = text
        @move_last_directory = @directory
        load_photo(next_filename)
      rescue => ex
        dialog = Gtk::MessageDialog.new(
          type: Gtk::MessageType::ERROR,
          message: "#{text}: #{ex}",
          buttons: :ok,
          parent: @window,
          flags: Gtk::DialogFlags::DESTROY_WITH_PARENT)
        dialog.run
        dialog.destroy
      end
    end

    if ask
      EntryDialog.new(
        title: "Move To", parent: @window,
        text: last,
        width_chars: @directory.size + 20,
        insert_text: photo_date) do |text|
        block.call(text)
      end
    else
      block.call(last)
    end
  end

  def save_last
    if @photo
      Last.find_or_create(directory: @directory) do |last|
        last.filename = @photo.filename
      end.update(filename: @photo.filename)
    end
  end

  def restore_last
    if @photo
      Last[@photo.directory]&.tap do |last|
        filename = last.filename
        if File.exist?(filename)
          load_photo(filename)
        end
      end
    end
  end

  def restore_scroll_when_idle(scrolled)
    adjustment = scrolled.vadjustment
    restore_scroll = Restore.new(adjustment.value) do |value|
      adjustment.set_value(value)
    end
    when_idle(&restore_scroll)
  end

  def when_idle(&block)
    id = GLib::Idle.add do
      block.call
      GLib::Source.remove(id)
    end
  end
end

class Rotator
  def initialize(list = [])
    @list = list.dup
  end

  def add(element)
    @list.delete(element)
    @list.unshift(element)
  end

  def current
    @list.first
  end

  def forwards
    e = @list.pop
    if e
      @list.unshift(e)
    end
    current
  end

  def backwards
    e = @list.shift
    if e
      @list.push(e)
    end
    current
  end
end

Tagger.new(ARGV)
Gtk.main
