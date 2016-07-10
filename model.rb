#!/usr/bin/env ruby

require "data_mapper"
require "gtk3"
require "pathname"
require "digest"
require "base64"
require "exiv2"
require "byebug"

# XXX Use Integer instead of DateTime?

class Photo
  include DataMapper::Resource

  property :id, Serial
  property :directory, String, length: 500, required: true, unique_index: :name
  property :basename, String, length: 500, required: true, unique_index: :name
  property :sha1, String, length: 28, required: true, index: :sha1
  property :filedate, DateTime, required: true # Date file was modified.
  property :taken_time, String, length: 100
  property :rating, Integer
  property :created_at, DateTime, required: true # Date this row was updated.

  has n, :tags, through: Resource

  # XXX can this cascade automatically?  XXX This is craxy.  This
  # isn't even called unless there are no constraints blocking the
  # destroy, so photo_tags must be deleted manually ahead of time.
  # before :destroy do
  #   photo_tags.each(&:destroy)
  # end
  def destroy
    # This is horrible.  Instead of cascade deleting the photo_tags, I
    # have to delete them manually then reload otherwise dm thinks
    # there are still photo_tags that will be left hanging.
    # XXX DM isn't setting up the schema with foreign keys, WTF?
    Photo.transaction do
      photo_tags.each(&:destroy)
    end
    reload
    super
  end

  def self.find_or_create(filename, &block)
    find_or_new(filename).tap do |photo|
      if photo.new?
        # Give the caller first chance to fill in values from xmp or
        # wherever.

        block && block.call(photo)

        # Now set anything the caller didn't.

        photo.filedate ||= File.mtime(photo.filename)
        photo.created_at ||= Time.now
        photo.taken_time ||= extract_time(photo.filename)

        if !photo.sha1
          photo.set_sha1
        end

        photo.save
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
    pixels = clear_edge(pixbuf)
    Base64.strict_encode64(Digest::SHA1.digest(pixels))
  end

  def self.clear_edge(pixbuf)
    pixbuf.pixels.tap do |pixels|
      row_width = pixbuf.width * pixbuf.n_channels * pixbuf.bits_per_sample / 8
      if row_width < pixbuf.rowstride
        # This loop is really slow if we don't pull some of these things
        # into a closure.
        zeros = "\0" * (pixbuf.rowstride - row_width)
        n = row_width
        size = zeros.size
        stride = pixbuf.rowstride
        # The last row is not padded out to the stride.
        0.upto(pixbuf.height - 2) do |row|
          pixels[n, size] = zeros
          n += stride
        end
      end
    end
  end

  def self.find_or_new(filename)
    realpath = Pathname.new(filename).realpath
    directory = realpath.dirname.to_s
    basename = realpath.basename.to_s

    first_or_new(directory: directory, basename: basename)
  end

  def self.find(filename)
    photo = find_or_new(filename)
    if !photo.new?
      photo
    else
      nil
    end
  end

  def filename
    File.join(directory, basename)
  end

  def identical
    Photo.all(sha1: self.sha1, :id.not => self.id)
  end

  def add_tag(string)
    # XXX I think this is supposed to work, but it only works if the tag
    # doesn't exist in which case it creates the tag and links it, else
    # it does nothing.
    # self.tags.first_or_create(tag: string)
    # So do it the hard way.
    tag = Tag.ensure(string)
    if !self.tags.include?(tag)
      self.tags << tag
      self.save
      #self.reload
      true
    end
  end

  def remove_tag(string)
    tag = self.tags.first(tag: string)
    if tag
      self.tags.delete(tag)
      self.save
      # Not sure why this is necessary, but it wors around the following:
      # - add_tag("x"): INSERT executed
      # - remove_tag("x"): DELETE executed
      # - add_tag("x"): no INSERT executed
      # DataMapper seems to think tag "x" is still applied and no INSERT
      # is required.
      self.reload
      true
    end
  end

  def set_rating(rating)
    self.rating = rating
    self.save
  end
end

class Tag
  include DataMapper::Resource

  property :id, Serial
  property :tag, String, length: 100, required: true, unique: true
  property :created_at, DateTime #, required: true

  has n, :photos, through: Resource

  def self.ensure(tag)
    Tag.first_or_create({tag: tag}, {created_at: Time.now})
  end
end

class Last
  include DataMapper::Resource

  property :directory, String, length: 5000, key: true
  property :filename, String, length: 5000, required: true
end

# Throw exceptions instead of silently returning false.
#
DataMapper::Model.raise_on_save_failure = true

# If you want the logs displayed you have to do this before the call to setup
#
DataMapper::Logger.new($stdout, :info)

module Model
  def self.setup(name, file)
    # A Sqlite3 connection to a persistent database
    #
    DataMapper.setup(name, "sqlite://#{file}")

    # XXX Not sure if this is per-repository or global.
    DataMapper.repository(name) do
      DataMapper.finalize
    end

    # Create the file+schema if it doesn't exist.
    #
    if !File.exist?(file)
      DataMapper.repository(name) do
        # XXX This is supposed to work but it only works for ;default.
        # It may have something to so with the Model's
        # default_repository_name.
        DataMapper.auto_migrate!
      end
    end
  end
end

# Grovel up the directory tree looking for a .taggerdb file to tell us
# what directory to use.  If not found, get it from the environment or
# use a default.

get_db = lambda do |dir|
  if dir == "/"
    "/home/tom/tagger/tags.db"
  else
    file = File.join(dir, ".taggerdb")
    if File.exist?(file)
      File.read(file).chomp
    else
      get_db.call(File.dirname(dir))
    end
  end
end

db_file = ENV["TAGGER_DB"] || get_db.call(Dir.pwd)

Model.setup(:default, db_file)
Photo.repository.adapter.execute("pragma journal_mode = truncate")
