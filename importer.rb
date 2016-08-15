require_relative "model"
require_relative "xmp"

module Importer
  def self.find_or_import_from_file(filename, copy_tags: false,
                                    purge_identical_images: false,
                                    force_purge: false)
    # Load an .xmp sidecar file is there is one.

    xmp_filename = "#{filename}.xmp"
    xmp = File.exist?(xmp_filename) && Xmp.new(File.read(xmp_filename))

    # Fetch or create a database entry.

    photo = Photo.find_or_create(filename) do |photo|
      # This is a new photo.  Fill in some things from xmp if we have
      # them.  Only constant values from the photo are set here, no
      # user-supplued values.  This saves some (a lot of) time.
      if xmp
        photo.sha1 = xmp.get_sha1
        photo.taken_time = xmp.get_taken_time
      end
    end

    # Always copy tags from an existing xmp sidecar file, even for an
    # existing photo.  Rating is copied only if the photo is unrated.
    # XXX This appends tags without replacing the existing tags.

    if xmp
      xmp.get_tags.each do |tag|
        photo.add_tag(tag)
      end
      if !photo.rating
        rating = xmp.get_rating
        if rating
          photo.set_rating(rating)
        end
      end
    end

    # If requested, add tags from existing identical images.
    # XXX this should be the default.

    if copy_tags
      photo.identical.each do |identical|
        identical.tags.each do |tag|
          photo.add_tag(tag)
        end
        if !photo.rating
          photo.rating = identical.rating
        end
      end
    end

    # If requested, purge identical images that no longer exist.  If
    # force_purge ten piurge them even if they do exist.

    if purge_identical_images
      photo.identical.each do |identical|
        if force_purge || !File.exist?(identical.filename)
          identical.destroy
        end
      end
    end

    photo
  end
end

