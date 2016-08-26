#!/usr/bin/env ruby

require "sequel"
require "logger"
require "gtk3"                  # For Gdk::Pixbuf
require "pathname"
require "digest"
require "exiv2"
require "byebug"

require_relative "files"

module Model
  # This makes association datasets "chainable" which makes tagged.rb
  # comceptually simpler, more like data_mapper.

  Sequel::Model.plugin :dataset_associations

  def self.setup(file)
    # Whether we need to create the schema.

    need_schema = !File.exist?(file)

    # A Sqlite3 connection to a persistent database

    Sequel.connect(
      "sqlite:#{file}",
      logger: Logger.new(STDOUT).tap do |logger|
        logger.level = Logger::WARN
      end
    ).tap do |db|
      db.use_timestamp_timezones = true
      db.run("pragma journal_mode = truncate")

      if need_schema
        create_schema(db)
      end
    end
  end

  def self.create_schema(db)
    db.create_table :photos do
      primary_key :id
      column :directory, String, size: 500, null: false
      column :basename, String, size: 500, null: false
      column :sha1, String, size: 28, null: false
      column :filedate, DateTime, null: false # Date file was modified.
      column :taken_time, String, size: 100, null: true
      column :rating, Integer, null: true
      column :created_at, DateTime, null: false # Date this row was updated.

      unique [:directory, :basename]
      index :sha1
    end

    db.create_table :tags do
      primary_key :id
      column :tag, String, size: 100, null: false
      column :created_at, DateTime, null: false

      unique :tag
    end

    # The photos/tags join table, cf. create_join_table
    #
    db.create_table :photos_tags do
      column :photo_id, Integer, null: false
      column :tag_id, Integer, null: false

      primary_key [:photo_id, :tag_id]
      unique [:tag_id, :photo_id]

      foreign_key [:photo_id], :photos, on_delete: :cascade
      foreign_key [:tag_id], :tags, on_delete: :cascade
    end

    db.create_table :lasts do
      column :directory, String, size: 500, primary_key: true
      column :filename, String, size: 500, null: false
    end
  end
end

# Grovel up the directory tree looking for a .taggerdb file to tell us
# what directory to use.  If not found, get it from the environment or
# use a default.

get_db = lambda do |dir|
  file = File.join(dir, ".taggerdb")
  if File.exist?(file)
    File.expand_path(File.read(file).chomp)
  else
    if dir == "/"
      dot_tagger = File.expand_path(File.join("~", ".tagger"))
      if !File.directory?(dot_tagger)
        Dir.mkdir(dot_tagger)
      end
      File.join(dot_tagger, "tags.db")
    else
      get_db.call(File.dirname(dir))
    end
  end
end

db_file = ENV["TAGGER_DB"] || get_db.call(Dir.pwd)

Model.setup(db_file)

class Photo < Sequel::Model
  many_to_many :tags
  # Don't need this with on_delete cascade.
  plugin :association_dependencies, tags: :nullify

  def self.find_or_create(filename, &block)
    super(split_filename(filename)) do |photo|
      # Give the caller first chance to fill in values from xmp or
      # wherever.

      block&.call(photo)

      # Now set anything the caller didn't.

      photo.filedate ||= File.mtime(photo.filename)
      photo.created_at ||= Time.now
      photo.taken_time ||= extract_time(photo.filename)

      if !photo.sha1
        photo.set_sha1
      end
    end
  end

  def self.extract_time(filename)
    # exiftool goes to great lengths to deal with non-conforming
    # dates.  No idea what exiv2 does if anything, other than writing
    # lots of warnings to stderr.
    date =
      begin
        exiv2 = Exiv2::ImageFactory.open(filename)
        exiv2.read_metadata
        exiv2.exif_data["Exif.Photo.DateTimeOriginal"]
      rescue
        nil
      end
    date = date.first if Array === date
    if date && date != "" && date !~ /^0/
      date, time = date.split(" ")
      date.gsub!(/:/, "-")
      "#{date} #{time}"
    end
  end

  def set_sha1
    self.sha1 = Photo.compute_sha1(self.filename)
  end

  def self.compute_sha1(filename)
    GC.start
    pixbuf = Gdk::Pixbuf.new(file: filename)	
    pixels = pixbuf.pixels
    row_width = pixbuf.width * pixbuf.n_channels * pixbuf.bits_per_sample / 8
    if row_width < pixbuf.rowstride
      stride = pixbuf.rowstride
      digest = Digest::SHA1.new
      0.upto(pixbuf.height - 1) do |row|
        digest << pixels[row * stride, row_width]
      end
      digest.base64digest
    else
      Digest::SHA1.base64digest(pixels)
    end
  end

  def self.find(filename)
    super(filename.is_a?(String) ? split_filename(filename) : filename)
  end

  def self.split_filename(filename)
    realpath = Pathname.new(filename).realpath
    {
      directory: realpath.dirname.to_s,
      basename: realpath.basename.to_s,
    }
  end

  def filename
    File.join(directory, basename)
  end

  def deleted?
    Files.deleted?(directory)
  end

  def date_string
    self.taken_time&.split&.first
  end

  def identical
    Photo.where(sha1: self.sha1).exclude(:id => self.id)
  end

  def add_tag(tag)
    if tag.is_a?(String)
      add_tag(Tag.ensure(tag))
    else
      if !self.tags.include?(tag)
        super(tag)
        true
      end
    end
  end

  def remove_tag(tag)
    if tag.is_a?(String)
      tag = self.tags.detect{|t| t.tag == tag}
      if tag
        remove_tag(tag)
        true
      end
    else
      super(tag)
    end
  end

  def set_rating(rating)
    self.rating = rating
    self.save
  end
end

class Tag < Sequel::Model
  many_to_many :photos
  # Don't need this with on_delete cascade.
  plugin :association_dependencies, photos: :nullify

  def self.ensure(tag)
    Tag.find_or_create(tag: tag) do |t|
      t.created_at = Time.now
    end
  end
end

class Last < Sequel::Model
  # Need this to allow first_or_create to set the directory column.
  unrestrict_primary_key
end
