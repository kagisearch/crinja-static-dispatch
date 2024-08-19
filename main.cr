require "crinja"
require "sqlite3"
require "json"

TYPES_COUNT = 1000

template_src = String.build do |s|
  TYPES_COUNT.times do |i|
    s << "{{" << "item" << i << "}}\n"
    s << "{{items}}\n"
  end
end
template = Crinja::Template.new(template_src)

{% for i in 0..TYPES_COUNT %}
  @[Crinja::Attributes]
  struct Test{{i}}
    include Crinja::Object::Auto
    include JSON::Serializable
    include DB::Serializable
    getter a : Int32 = {{i}}
    getter b : String = {{i.stringify}}

    def initialize
    end
  end
  template.env.context[{{"item" + i.stringify}}] = Test{{i}}.new
{% end %}

array = nil
{% begin %}
  {% lit = [] of Nil %}
  {% for i in 0..TYPES_COUNT %}
    {% lit.push("Test#{i}.new".id) %}
  {% end %}
  array = {{ lit }}
{% end %}

puts(template.render({items: array}))
