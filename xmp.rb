require "nokogiri"
require "byebug"

class Xmp
  NAMESPACES = {
    "x" => "adobe:ns:meta/",
    "dc" => "http://purl.org/dc/elements/1.1/",
    "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "xmp" => "http://ns.adobe.com/xap/1.0/",
    "tg" => "http://tagger.tommay.net/",
  }.freeze

  # I want to_xml (below) to return nicely formatted xml.  But it
  # seems that if there is a newline Text node as a child of xmpmeta
  # then the output isn't formatted.  Using "noblanks" should suppress
  # this but it doesn't.  So use gsub here to get rid of the newlines.
  # Strings read back from existing xmp files are ok because they
  # don't have empty nodes.  XXX That may not be true for files
  # created by arbitrary programs.
  #
  MINIMAL = <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 4.4.0-Exiv2">
</x:xmpmeta>
EOF
  .gsub("\n", "")

  def initialize(string=MINIMAL)
    @xmp = Nokogiri::XML(string) do |config|
      config.default_xml.noblanks
    end
  end

  def get_tags
    @xmp.css("dc|subject rdf|li", NAMESPACES).map do |tag|
      tag.text
    end
  end

  def add_tag(tag)
    if !get_tags.include?(tag)
      description = find_or_add_description
      subject = find_or_add_child(description, "dc:subject")
      seq = find_or_add_child(subject, "rdf:Seq")
      li = Nokogiri::XML::Node.new("rdf:li", @xmp)
      li.content = tag
      seq.add_child(li)
    end
  end

  def_attr = lambda do |name|
    define_method(:"get_#{name}") do
      description = @xmp.at_css("rdf|Description", NAMESPACES)
      description&.attribute_with_ns(name, NAMESPACES["tg"])&.value
    end

    define_method(:"set_#{name}") do |value|
      description = find_or_add_description
      set_attribute(description, "tg:#{name}", value.to_s)
    end
  end

  def_attr.call("sha1")
  def_attr.call("taken_time")
  def_attr.call("rating")

  def find_or_add_description
    xmpmeta = @xmp.at_css("x|xmpmeta", NAMESPACES)
    rdf = find_or_add_child(xmpmeta, "rdf:RDF")
    find_or_add_child(rdf, "rdf:Description")
  end

  def find_or_add_child(node, name)
    (prefix, name) = name.split(/:/, 2)
    child = node.at_css("#{prefix}|#{name}", NAMESPACES)
    if !child
      # Use an existing namespace if posssible.
      existing_ns = node.namespaces.invert[NAMESPACES[prefix]]
      if existing_ns
        prefix = existing_ns.sub(/^xmlns:/, "")
        child = Nokogiri::XML::Node.new("#{prefix}:#{name}", node.document)
      else
        child = Nokogiri::XML::Node.new("#{prefix}:#{name}", node.document)
        child.add_namespace(prefix, NAMESPACES[prefix])
      end
      node.add_child(child)
    end
    child
  end

  def set_attribute(node, name, value)
    (prefix, name) = name.split(/:/, 2)
    prefix = find_or_add_namespace(node, prefix)
    node["#{prefix}:#{name}"] = value
  end

  def find_or_add_namespace(node, prefix)
    # Use an existing namespace if posssible.
    existing_ns = node.namespaces.invert[NAMESPACES[prefix]]
    if existing_ns
      existing_ns.sub(/^xmlns:/, "")
    else
      node.add_namespace(prefix, NAMESPACES[prefix])
      prefix
    end
  end

  def to_s
    @xmp.to_xml(indent: 2)
  end
end
