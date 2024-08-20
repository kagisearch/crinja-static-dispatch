require "crinja"

TYPES_COUNT     =   1
FIELDS_PER_TYPE = 250 # 250 fields =~ 2kb struct with i64

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

    {% for j in 0..FIELDS_PER_TYPE %}
      getter field{{j}} : Int64 = {{j}}
    {% end %}

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

{% for i in 0..TYPES_COUNT %}
  template.render({item: Test{{i}}.new})
  template.render({item: [Test{{i}}.new]})
{% end %}
