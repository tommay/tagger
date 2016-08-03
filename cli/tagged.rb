#!/usr/bin/env ruby

require "bundler/setup"
require "trollop"
require "strscan"
require "pratt_parser"
require "byebug"
require_relative "../model"

options = Trollop::options do
  banner "Usage: #{$0} [-]tag..."
  opt :nul, "Nul-terminate output filenames"
  opt :null, "Same as --nul"
  opt :tags, "Show files' tags"
  opt :ugly, "Show files' tags in tag -a ... format"
  opt :directories, "List only directories containing the files"
  opt :expr, "Expression to search for", type: String
  conflicts :nul, :tags, :ugly
  conflicts :null, :tags, :ugly
  conflicts :directories, :tags, :ugly
  stop_on_unknown
end

terminator = (options.nul || options.null) ? "\0" : "\n"

@directories = {}

# Lexer for PrattParser to create the Photo collection based on a
# tag/date expression.

class Lexer
  # Tokens are:
  #  [-]tag
  #  <date
  #  =date
  #  >date
  #  r:[12345]*
  #  +
  #  (
  #  )
  # where tag is a string of non-blanks or delimited by double quotes
  # and date is a string of digits and dashes, any prefix of
  # yyyy-mm-dd.  TOKENS matches each token in the expression.  -tag
  # yields two tokens: AndNotToken which is an operator, and
  # LikeTagToken(tag).  AndToken is generated automatically between
  # two tag or date tokens that don't have an explicit operator (+ or
  # -) between them.  All operators have the same precedence and are
  # left-associative.
  #
  # None of this scanning stuff is pretty but I blame it on my desire
  # to support command lines like "tagged max boots" to find photos
  # tagged with both "max" and "boots", and "tagged 'max boots'" to
  # find photos with the single tag "max boots".  And also to allow
  # "tagged max -boots" to find photos tagged with "max' but not with
  # "boots".
  #
  # XXX This is still crap because the expression " will be handled as
  # a tag.

  TOKENS = /[+()]|[<>=][0-9\-]+|r:[1-5]*|-?"([^"]*)"|-?[^\s]+|\s+/

  # Note that new is overwritten to return an Enumerator, not a Lexer.

  def self.new(expression)
    scanner = StringScanner.new(expression)
    need_and = false
    Enumerator.new do |y|
      while !scanner.eos?
        case scanner.scan(TOKENS)
        when nil
          raise "scan error at #{scanner.rest}"
        when /^\s+$/
          # Ignore whitespace.
        when "("
          y << LeftParenToken.new
          need_and = false
        when ")"
          y << RightParenToken.new
          need_and = true
        when "+"
          y << PlusToken.new
          need_and = false
        when /^=(.*)/
          y << AndToken.new if need_and
          y << LikeDateToken.new($1)
          need_and = true
        when /^<(.*)/
          y << AndToken.new if need_and
          y << BeforeDateToken.new($1)
          need_and = true
        when /^>(.*)/
          y << AndToken.new if need_and
          y << AfterDateToken.new($1)
          need_and = true
        when /^r:([1-5]*)$/
          y << AndToken.new if need_and
          y << RatingToken.new($1)
          need_and = true
        when /^-"(.*)"/, /^-(.*)/
          y << ButNotToken.new
          y << LikeTagToken.new($1)
          need_and = true
        when /^"(.*)"/, /^(.*)/
          y << AndToken.new if need_and
          y << LikeTagToken.new($1)
          need_and = true
        end
      end
    end
  end

  def self.Token(_lbp)
    Class.new do
      define_method(:lbp) do
        _lbp
      end
    end
  end

  class PhotoToken < Token(100)
    def initialize(*args)
      @photos = photos(*args)
    end

    def nud(parser)
      @photos
    end
  end

  class LikeTagToken < PhotoToken
    def photos(tag)
      if tag =~ /%/
        Tag.all(:tag.like => tag).photos
      else
        Tag.all(:tag => tag).photos
      end
    end
  end

  class LikeDateToken < PhotoToken
    def photos(date)
      Photo.all(:taken_time.like => date + "%")
    end
  end

  class BeforeDateToken < PhotoToken
    def photos(date)
      Photo.all(:taken_time.lt => date)
    end
  end

  class AfterDateToken < PhotoToken
    def photos(date)
      Photo.all(:taken_time.gte => date)
    end
  end

  class RatingToken < PhotoToken
    def photos(ratings)
      if ratings == ""
        Photo.all(rating: nil)
      else
        Photo.all(rating: ratings.each_char.map{|c| c.to_i})
      end
    end
  end

  def self.BinaryOpToken(op)
    Token(10).tap do |klass|
      klass.class_exec do
        define_method(:led) do |parser, left|
          left.send(op, parser.expression(lbp))
        end
      end
    end
  end

  AndToken = BinaryOpToken(:&)
  PlusToken = BinaryOpToken(:+)
  ButNotToken = BinaryOpToken(:-)

  class LeftParenToken < Token(1)
    def nud(parser)
      parser.expression(lbp).tap do
        parser.expect(RightParenToken)
      end
    end
  end
  
  class RightParenToken < Token(1)
  end
end

expression = options.expr || ARGV.map do |arg|
  case arg
  when /^[<>=]/
    arg
  when /^-(.*)/
    "-\"#{$1}\""
  when /^r:[1-5]*$/
    arg
  else
    "\"#{arg}\""
  end
end.join(" ")

photos = PrattParser.new(Lexer.new(expression)).eval

def quote(s)
  s.gsub(/\\/, "\\\\")
  s.gsub(/"/, "\\\"")
  s.gsub(/\$/, "\\$")
  "\"#{s}\""
end

if options.tags || options.ugly
  photos = photos.map do |photo|
    [photo.filename, photo.tags.map{|t|t.tag}.sort]
  end

  photos.sort.each do |photo|
    if options.ugly
      photo[1].each { |t| print " -a #{quote(t)}" }
      puts " #{quote(photo[0])}"
    else
      puts "#{photo[0]}: #{photo[1].join(", ")}"
    end
  end
else
  filenames = photos.map do |photo|
    photo.filename
  end

  filenames.sort.each do |filename|
    if !options.directories
      puts "#{filename}#{terminator}"
    else
      dirname = File.dirname(filename)
      if !@directories[dirname]
        @directories[dirname] = true
        puts dirname
      end
    end
  end
end
