This repo is a workspace for exploring the compile-time and code-size impact believed to be caused by Crystal's means of static dispatch.

The case study is built on [`crinja`](https://github.com/straight-shoota/crinja), a port of the Jinja templating engine to Crystal.

## Case Study

### First Report

At Kagi, we have been building on top of Crinja for a while now, but we noticed an impact on our build times soon after we had started implementing it into our framework.
I quickly did an analysis as best I could and wrote an [initial report](https://gist.github.com/z64/e51dd07a5c3ef5418590945bd4eecdb4).

Most of the rest of this article will assume you have read this report, but in summary:
- Traditionally, we have seen a correlation between large function sizes and build times
- Analysis of our binary found that crinja contributes the largest functions, megabytes of code in size
- Deleting or suppressing the offending code saw a dramatic uptick in build times
- Root cause seemed to be a large switch path generated for static dispatch, facilitating Crinja's `Value` types, etc.

My prognosis was that the cost that we were paying was either a "one-time fee" or otherwise would grow at a much slower rate.
But it turned out when I repeat the test from my original report today, this cost we were paying had more than doubled.
Removing the largest Crinja functions from our binary brought back 30s+ of dev build time.

### Second Attempt

At time of writing, we exported some 50 types to Crinja via the `include Crinja::Object`(`::Auto`) mechanism.
On my machine, as a baseline, build times were on average 60-70s.

Taking another crack at it, I took the following approach:

1. Remove every single `include Crinja::Object` from our tree
2. Build and record the baseline build time and top function sizes
3. Add each `include Crinja::Object` back one by one
4. Observe each types impact on build time and function sizes
5. Repeat until they are all added back or we otherwise reach some explanation

Function sizes provided by the following command:

```sh
nm --size-sort --print-size ~/.cache/crystal/home-lune-git-kagi-kagi-search-src-entrypoint.cr/_main.o0.o | rg 'crinja' | tail -n20
```

So, how did it go?
I added back several types - 7 or 8 - and we were still pretty "fast" at about 30 seconds.
Top crinja-related function sizes were reading as so:

```
00000000001ac900 000000000000f24d T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:198
000000000016dd40 0000000000012e9c T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:186
000000000015ae60 0000000000012edc T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:182
0000000000146970 00000000000144ee T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:125
0000000000196a90 0000000000015e6d T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:194
0000000000180be0 0000000000015ead T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:190
000000000012bfe0 000000000001a424 T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:99
```
> The format of this output, in columns left to right, is <address, size, symbol>.

Our largest function of the set sitting at about 105kb.
Big, but nothing spectacular.
Let's add another type.

```
00000000019d1ea0 00000000002df18f T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:198
0000000000b5f7a0 000000000034b5de T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:182
0000000000eaad80 000000000034b5fe T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:186
00000000007c13c0 000000000039e3d6 T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:125
00000000011f6380 00000000003edd7b T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:190
00000000015e4100 00000000003edd9b T ~procProc(Crinja::Arguments, Crinja::Value)@lib/crinja/src/lib/filter/collections.cr:194
```

That's almost 4MB! And my build time almost immediately went to 60s. What happened!?

### Cause, Analysis... and workaround!

The type I added back to the build was something called `QueryCtx`.
It is a foundational type of our framework that is a grab-bag of anything you would want to know about the request, from the HTTP request details, session details such as a the current user and their billing state, and a bunch of common utility functions.

The type is a struct, and is defined like so:
```crystal
abstract struct QueryCtx
  # ...
  include Crinja::Object
end
```

> The `abstract` bit I believe to be irrelevant to the topic / root cause; the subtyping exists to abstract certain client repsonse modes.
> There are only 4 subtypes and they just add a couple methods each.

As we've grown, we've kinda just tossed more and more stuff on here, up to 1.7kb of data, and it has been fine.
The value semantics were also important for how our early framework operated, for very cheap scope or fiber-local overrides of values, where we didn't have to worry about shared mutation.
(We've well moved on to something else by now, but the migration is still WIP, so this code stands)

However, here `include Crinja::Object` (this did *not* use `::Auto`) has thrown a wrench in things.
It clearly has made something in `lib/filter/collections` quite upset.

Thankfully, I was able to fix it easily and precisely; I created a simple proxy type:

```crystal
class QueryCtxJinjaProxy
  include Jinja::Object

  def initialize(@ctx : QueryCtx)
  end

  def crinja_attribute(attr : Jinja::Value) : Jinja::Value
    # ...
  end

  def crinja_call(name : String) : Jinja::Callable | Jinja::Callable::Proc | Nil
    # ...
  end
end
```

And, just in time, wrap ourselves in this proxy inside `QueryCtx#render`:

```crystal
def render(template : String, vars = nil) : String
  template = JINJA.get_template(template)
  if vars
    @jinja_context.merge!(vars) 
  end
  @jinja_context["ctx"] = QueryCtxJinjaProxy.new(self)
  template.render(@jinja_context)
end
```

`QueryCtx` was no longer a `Crinja::Object`. But, our templates still had access to it, and our build times were relieved.

### Conclusion

The interesting bit to me was that now that I had this proxy type, I discovered that I could change it to `struct` and immediately get the regressed build times back.
To me this was a clear signal that it has something to do with value size alone, and not necessarily any of the implementation details of `QueryCtx`.

This is roughly about as far as I've gotten so far.
I have squinted at the LLVM IR of both `struct` and `class` versions and nothing jumped out at me.
In fact, in the largest function cited from `nm`, the IR for that function was about a thousand lines shorter in the slower build with `struct` than the faster one with `class`.
(Of course, it is not a hard rule that more IR = slower to build, but it is *usually* the case IME)

[*Continuing in the Crystal Discord*](https://discord.com/channels/591460182777790474/1271123999103127615/1275378738372280322) ([invite](https://discord.gg/YS7YvQy))

## This repo

Now, while I was in the middle of all of that, I started setting this repo up on the side so that I could play with automatically creating some stress tests for what I suspected to be causing build time pressure.

It is nothing scientific, not a "minimal" example; its a set of levers to generate some sufficiently complex code that *seems* to exhibit the same growth pattern; which is, many large structs = slow build with big functions inside.

Check `main.cr` for some settings in constants at the top.
Try the following, in combintations:
- Changing `TYPES_COUNT`
- Changing `FIELDS_PER_TYPE`
- Changing `struct` to `class`
- Changing `field` to `Int32` instead of `Int64`

Running `make` will build then output the top function sizes from `nm`.
See the `Makefile`, you'll have to plug in the path to your cache directory. (sorry)

You should see comparable results - a few very large types (approaching 2kb) dramatically affects build time and function sizes, or a lot (100) of moderately sized ones will also do the trick.
