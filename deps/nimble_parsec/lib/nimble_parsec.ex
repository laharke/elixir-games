defmodule NimbleParsec do
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  defmacrop is_combinator(combinator) do
    quote do
      is_list(unquote(combinator))
    end
  end

  @doc """
  Defines a parser (and a combinator) with the given `name` and `opts`.

  The parser is a function that receives two arguments, the binary
  to be parsed and a set of options. You can consult the documentation
  of the generated parser function for more information.

  This function will also define a combinator that can be used as
  `parsec(name)` when building other parsers. See `parsec/2` for
  more information on invoking compiled combinators.

  ## Beware!

  `defparsec/3` is executed during compilation. This means you can't
  invoke a function defined in the same module. The following will error
  because the `date` function has not yet been defined:

      defmodule MyParser do
        import NimbleParsec

        def date do
          integer(4)
          |> ignore(string("-"))
          |> integer(2)
          |> ignore(string("-"))
          |> integer(2)
        end

        defparsec :date, date()
      end

  This can be solved in different ways. You may simply
  compose a long parser using variables. For example:

      defmodule MyParser do
        import NimbleParsec

        date =
          integer(4)
          |> ignore(string("-"))
          |> integer(2)
          |> ignore(string("-"))
          |> integer(2)

        defparsec :date, date
      end

  Alternatively, you may define a `Helpers` module with many
  convenience combinators, and then invoke them in your parser
  module:

      defmodule MyParser.Helpers do
        import NimbleParsec

        def date do
          integer(4)
          |> ignore(string("-"))
          |> integer(2)
          |> ignore(string("-"))
          |> integer(2)
        end
      end

      defmodule MyParser do
        import NimbleParsec
        import MyParser.Helpers

        defparsec :date, date()
      end

  The approach of using helper modules is the favorite way
  of composing parsers in `NimbleParsec`.

  ## Options

    * `:inline` - when true, inlines clauses that work as redirection for
      other clauses. Settings this may improve runtime performance at the
      cost of increased compilation time and bytecode size

    * `:debug` - when true, writes generated clauses to `:stderr` for debugging

    * `:export_combinator` - make the underlying combinator function public
      so it can be used as part of `parsec/1` from other modules

    * `:export_metadata` - export metadata necessary to use this parser
      combinator to generate inputs

  """
  defmacro defparsec(name, combinator, opts \\ []) do
    visibility =
      quote do
        if opts[:export_combinator], do: :def, else: :defp
      end

    compile(:def, visibility, name, combinator, opts)
  end

  @doc """
  Defines a private parser (and a combinator) with the given `name` and `opts`.

  The same as `defparsec/3` but the parsing function is private.
  """
  defmacro defparsecp(name, combinator, opts \\ []) do
    compile(:defp, :defp, name, combinator, opts)
  end

  @doc """
  Defines a combinator with the given `name` and `opts`.

  It is similar to `defparsec/3` except it does not define
  an entry-point parsing function, just the combinator function
  to be used with `parsec/2`.
  """
  defmacro defcombinator(name, combinator, opts \\ []) do
    compile(nil, :def, name, combinator, opts)
  end

  @doc """
  Defines a combinator with the given `name` and `opts`.

  It is similar to `defparsecp/3` except it does not define
  an entry-point parsing function, just the combinator function
  to be used with `parsec/2`.
  """
  defmacro defcombinatorp(name, combinator, opts \\ []) do
    compile(nil, :defp, name, combinator, opts)
  end

  defp compile(parser_kind, combinator_kind, name, combinator, opts) do
    prelude =
      quote do
        opts = unquote(opts)
        combinator_kind = unquote(combinator_kind)
      end

    combinator =
      quote bind_quoted: [
              parser_kind: parser_kind,
              name: name,
              combinator: combinator
            ] do
        {defs, inline} = NimbleParsec.Compiler.compile(name, combinator, opts)

        NimbleParsec.Recorder.record(
          __MODULE__,
          parser_kind,
          combinator_kind,
          name,
          defs,
          inline,
          opts
        )

        if opts[:export_metadata] do
          def __nimble_parsec__(unquote(name)),
            do: unquote(combinator |> Enum.reverse() |> Macro.escape())
        end

        if inline != [] do
          @compile {:inline, inline}
        end

        if combinator_kind == :def do
          for {name, args, guards, body} <- defs do
            def unquote(name)(unquote_splicing(args)) when unquote(guards), do: unquote(body)
          end
        else
          for {name, args, guards, body} <- defs do
            defp unquote(name)(unquote_splicing(args)) when unquote(guards), do: unquote(body)
          end
        end
      end

    parser = compile_parser(name, parser_kind)

    quote do
      unquote(prelude)
      unquote(parser)
      unquote(combinator)
    end
  end

  defp compile_parser(_name, nil) do
    :ok
  end

  defp compile_parser(name, :def) do
    quote bind_quoted: [name: name] do
      {doc, spec, {name, args, guards, body}} = NimbleParsec.Compiler.entry_point(name)
      Module.get_attribute(__MODULE__, :doc) || @doc doc
      @spec unquote(spec)
      def unquote(name)(unquote_splicing(args)) when unquote(guards), do: unquote(body)
    end
  end

  defp compile_parser(name, :defp) do
    quote bind_quoted: [name: name] do
      {_doc, spec, {name, args, guards, body}} = NimbleParsec.Compiler.entry_point(name)
      @spec unquote(spec)
      defp unquote(name)(unquote_splicing(args)) when unquote(guards), do: unquote(body)
    end
  end

  @opaque t :: [combinator]
  @type bin_modifier :: :integer | :utf8 | :utf16 | :utf32
  @type range :: inclusive_range | exclusive_range
  @type inclusive_range :: Range.t() | char
  @type exclusive_range :: {:not, Range.t()} | {:not, char}
  @type min_and_max :: {:min, non_neg_integer} | {:max, pos_integer}
  @type call :: mfargs | fargs | atom
  @type mfargs :: {module, atom, args :: [term]}
  @type fargs :: {atom, args :: [term]}
  @type gen_times :: Range.t() | non_neg_integer | nil
  @type gen_weights :: [pos_integer] | nil
  @type opts :: Keyword.t()

  # Steps to add a new combinator:
  #
  #   1. Update the combinator type below
  #   2. Update the compiler with combinator
  #   3. Update the compiler with label step
  #
  @typep combinator :: bound_combinator | maybe_bound_combinator | unbound_combinator

  @typep bound_combinator ::
           {:bin_segment, [inclusive_range], [exclusive_range], bin_modifier}
           | {:string, binary}
           | {:bytes, pos_integer}
           | :eos

  @typep maybe_bound_combinator ::
           {:label, t, binary}
           | {:traverse, t, :pre | :post | :constant, [mfargs]}

  @typep unbound_combinator ::
           {:choice, [t], gen_weights}
           | {:eventually, t}
           | {:lookahead, t, :positive | :negative}
           | {:parsec, atom | {module, atom}}
           | {:repeat, t, mfargs, gen_times}
           | {:times, t, pos_integer}

  @doc ~S"""
  Generate a random binary from the given parsec.

  Let's see an example:

      import NimbleParsec
      generate(choice([string("foo"), string("bar")]))

  The command above will return either "foo" or "bar". `generate/1`
  is often used with pre-defined parsecs. In this case, the
  `:export_metadata` flag must be set:

      defmodule SomeModule do
        import NimbleParsec
        defparsec :parse,
                  choice([string("foo"), string("bar")]),
                  export_metadata: true
      end

      # Reference the parsec and generate from it
      NimbleParsec.parsec({SomeModule, :parse})
      |> NimbleParsec.generate()
      |> IO.puts()

  `generate/1` can often run forever for recursive algorithms.
  Read the notes below and make use of the `gen_weight` and `gen_times`
  option to certain parsecs to control the recursion depth.

  ## Notes

  Overall, there is no guarantee over the generated output, except
  that it will generate a binary that is parseable by the parsec
  itself, but even this guarantee may be broken by parsers that have
  custom validations. Keep in mind the following:

    * `generate/1` is not compatible with NimbleParsecs dumped via
      `mix nimble_parsec.compile`;

    * `parsec/2` requires the referenced parsec to set `export_metadata: true`
      on its definition;

    * `choice/2` will be generated evenly. You can pass `:gen_weights`
      as a list of positive integer weights to balance your choices.
      This is particularly important for recursive algorithms;

    * `repeat/2` and `repeat_while/3` will repeat between 0 and 3 times unless
      a `:gen_times` option is given to these operations. `times/3` without a `:max`
      will also additionally repeat between 0 and 3 times unless `:gen_times` is given.
      The `:gen_times` option can either be an integer as the number of times to
      repeat or a range where a random value in the range will be picked;

    * `eventually/2` always generates the eventually parsec immediately;

    * `lookahead/2` and `lookahead_not/2` are simply discarded;

    * Validations done in any of the traverse definitions are not taken into account
      by the generator. Therefore, if a parsec does validations, the generator may
      generate binaries invalid to said parsec;

  """
  def generate(parsecs) do
    parsecs
    |> Enum.reverse()
    |> generate(nil, [])
    |> IO.iodata_to_binary()
  end

  defp generate([{:parsec, fun} | _parsecs], nil, _acc) when is_atom(fun) do
    raise "cannot generate parsec(#{inspect(fun)}), use a remote parsec instead"
  end

  defp generate([{:parsec, fun} | parsecs], mod, acc) when is_atom(fun) do
    generate([{:parsec, {mod, fun}} | parsecs], mod, acc)
  end

  defp generate([{:parsec, {mod, fun}} | outer_parsecs], outer_mod, acc) do
    gen = generate(gen_export(mod, fun), mod, [])
    generate(outer_parsecs, outer_mod, [gen | acc])
  end

  defp generate([{:string, string} | parsecs], mod, acc) do
    generate(parsecs, mod, [string | acc])
  end

  defp generate([{:bin_segment, inclusive, exclusive, modifier} | parsecs], mod, acc) do
    gen = gen_bin_segment(inclusive, exclusive)

    gen =
      if modifier == :integer,
        do: gen,
        else: :unicode.characters_to_binary([gen], :unicode, modifier)

    generate(parsecs, mod, [gen | acc])
  end

  defp generate([:eos | parsecs], mod, acc) do
    if parsecs == [] do
      generate([], mod, acc)
    else
      raise ArgumentError, "found :eos not at the end of parsecs"
    end
  end

  defp generate([{:traverse, t, _, _} | parsecs], mod, acc) do
    generate(t ++ parsecs, mod, acc)
  end

  defp generate([{:label, t, _} | parsecs], mod, acc) do
    generate(t ++ parsecs, mod, acc)
  end

  defp generate([{:choice, choices, weights} | parsecs], mod, acc) do
    pick = if weights, do: weighted_random(choices, weights), else: list_random(choices)
    gen = generate(pick, mod, [])
    generate(parsecs, mod, [gen | acc])
  end

  defp generate([{:lookahead, _, _} | parsecs], mod, acc) do
    generate(parsecs, mod, acc)
  end

  defp generate([{:repeat, t, _, gen} | parsecs], mod, acc) do
    generate(parsecs, mod, gen_times(t, int_random(gen), mod, acc))
  end

  defp generate([{:times, t, max} | parsecs], mod, acc) do
    generate(parsecs, mod, gen_times(t, Enum.random(0..max), mod, acc))
  end

  defp generate([{:bytes, count} | parsecs], mod, acc) do
    bytes = bytes_random(count)
    generate(parsecs, mod, [bytes | acc])
  end

  defp generate([], _mod, acc), do: Enum.reverse(acc)

  defp gen_export(mod, fun) do
    unless Code.ensure_loaded?(mod) do
      raise "cannot handle parsec(#{inspect({mod, fun})}) because #{inspect(mod)} is not available"
    end

    try do
      mod.__nimble_parsec__(fun)
    rescue
      _ ->
        raise "cannot handle parsec(#{inspect({mod, fun})}) because #{inspect(mod)} " <>
                "did not set :export_metadata when defining #{fun}"
    end
  end

  defp gen_times(_t, 0, _mod, acc), do: acc

  defp gen_times(t, n, mod, acc) do
    gen = generate(t, mod, [])
    gen_times(t, n - 1, mod, [gen | acc])
  end

  defp gen_bin_segment(inclusive, exclusive) do
    gen =
      if(inclusive == [], do: [0..255], else: inclusive)
      |> list_random()
      |> int_random()

    if Enum.any?(exclusive, &exclude_bin_segment?(&1, gen)) do
      gen_bin_segment(inclusive, exclusive)
    else
      gen
    end
  end

  defp exclude_bin_segment?({:not, _.._//_ = range}, gen), do: gen in range
  defp exclude_bin_segment?({:not, char}, gen) when is_integer(char), do: char == gen

  defp int_random(nil), do: Enum.random(0..3)
  defp int_random(_.._//_ = range), do: Enum.random(range)
  defp int_random(int) when is_integer(int), do: int

  # Enum.random uses reservoir sampling but our lists are short, so we use length + fetch!
  defp list_random(list) when is_list(list),
    do: Enum.fetch!(list, :rand.uniform(length(list)) - 1)

  defp weighted_random(list, weights) do
    weighted_random(list, weights, :rand.uniform(Enum.sum(weights)))
  end

  defp weighted_random([elem | _], [weight | _], chosen) when chosen <= weight,
    do: elem

  defp weighted_random([_ | list], [weight | weights], chosen),
    do: weighted_random(list, weights, chosen - weight)

  defp bytes_random(count) when is_integer(count) do
    :crypto.strong_rand_bytes(count)
  end

  @doc ~S"""
  Returns an empty combinator.

  An empty combinator cannot be compiled on its own.
  """
  @spec empty() :: t
  def empty() do
    []
  end

  @doc """
  Invokes an already compiled combinator with name `name` in the
  same module.

  Every parser defined via `defparsec/3` or `defparsecp/3` can be
  used as combinator. However, the `defparsec/3` and `defparsecp/3`
  functions also define an entry-point parsing function, as implied
  by their names. If you want to define a combinator with the sole
  purpose of using it in combinator, use `defcombinatorp/3` instead.

  ## Use cases

  `parsec/2` is useful to implement recursive definitions.

  Note, while `parsec/2` can be used to compose smaller combinators,
  the preferred mechanism for doing composition is via regular functions
  and not via `parsec/2`. Let's see a practical example. Imagine
  that you have this module:

      defmodule MyParser do
        import NimbleParsec

        date =
          integer(4)
          |> ignore(string("-"))
          |> integer(2)
          |> ignore(string("-"))
          |> integer(2)

        time =
          integer(2)
          |> ignore(string(":"))
          |> integer(2)
          |> ignore(string(":"))
          |> integer(2)
          |> optional(string("Z"))

        defparsec :datetime, date |> ignore(string("T")) |> concat(time), debug: true
      end

  Now imagine that you want to break `date` and `time` apart
  into helper functions, as you use them in other occasions.
  Generally speaking, you should **NOT** do this:

      defmodule MyParser do
        import NimbleParsec

        defcombinatorp :date,
                       integer(4)
                       |> ignore(string("-"))
                       |> integer(2)
                       |> ignore(string("-"))
                       |> integer(2)

        defcombinatorp :time,
                       integer(2)
                       |> ignore(string(":"))
                       |> integer(2)
                       |> ignore(string(":"))
                       |> integer(2)
                       |> optional(string("Z"))

        defparsec :datetime,
                  parsec(:date) |> ignore(string("T")) |> concat(parsec(:time))
      end

  The reason why the above is not recommended is because each
  `parsec/2` combinator ends-up adding a stacktrace entry during
  parsing, which affects the ability of `NimbleParsec` to optimize
  code. If the goal is to compose combinators, you can do so
  with modules and functions:

      defmodule MyParser.Helpers do
        import NimbleParsec

        def date do
          integer(4)
          |> ignore(string("-"))
          |> integer(2)
          |> ignore(string("-"))
          |> integer(2)
        end

        def time do
          integer(2)
          |> ignore(string(":"))
          |> integer(2)
          |> ignore(string(":"))
          |> integer(2)
          |> optional(string("Z"))
        end
      end

      defmodule MyParser do
        import NimbleParsec
        import MyParser.Helpers

        defparsec :datetime,
                  date() |> ignore(string("T")) |> concat(time())
      end

  The implementation above will be able to compile to the most
  efficient format as possible without forcing new stacktrace
  entries.

  The only situation where you should use `parsec/2` for composition
  is when a large parser is used over and over again in a way
  compilation times are high. In this sense, you can use `parsec/2`
  to improve compilation time at the cost of runtime performance.
  By using `parsec/2`, the tree size built at compile time will be
  reduced although runtime performance is degraded as `parsec`
  introduces a stacktrace entry.

  ## Remote combinators

  You can also reference combinators in other modules by passing
  a tuple with the module name and a function to `parsec/2` as follows:

      defmodule RemoteCombinatorModule do
        defcombinator :upcase_unicode, utf8_char([...long, list, of, unicode, chars...])
      end

      defmodule LocalModule do
        # Parsec that depends on `:upcase_A`
        defparsec :parsec_name,
                  ...
                  |> ascii_char([?a..?Z])
                  |> parsec({RemoteCombinatorModule, :upcase_unicode})
      end

  Remote combinators are useful when breaking the compilation of
  large modules apart in order to use Elixir's ability to compile
  modules in parallel.

  ## Examples

  A good example of using `parsec` is with recursive parsers.
  A limited but recursive XML parser could be written as follows:

      defmodule SimpleXML do
        import NimbleParsec

        tag = ascii_string([?a..?z, ?A..?Z], min: 1)
        text = ascii_string([not: ?<], min: 1)

        opening_tag =
          ignore(string("<"))
          |> concat(tag)
          |> ignore(string(">"))

        closing_tag =
          ignore(string("</"))
          |> concat(tag)
          |> ignore(string(">"))

        defparsec :xml,
                  opening_tag
                  |> repeat(lookahead_not(string("</")) |> choice([parsec(:xml), text]))
                  |> concat(closing_tag)
                  |> wrap()
      end

      SimpleXML.xml("<foo>bar</foo>")
      #=> {:ok, [["foo", "bar", "foo"]], "", %{}, {1, 0}, 14}

  In the example above, `defparsec/3` has defined the entry-point
  parsing function as well as a combinator which we have invoked
  with `parsec(:xml)`.

  In many cases, however, you want to define recursive combinators
  without the entry-point parsing function. We can do this by
  replacing `defparsec/3` by `defcombinatorp`:

      defcombinatorp :xml,
                     opening_tag
                     |> repeat(lookahead_not(string("</")) |> choice([parsec(:xml), text]))
                     |> concat(closing_tag)
                     |> wrap()

  When using `defcombinatorp`, you can no longer invoke
  `SimpleXML.xml(xml)` as there is no associated parsing function.
  You can only access the combinator above via `parsec/2`.
  """
  @spec parsec(name :: atom) :: t
  @spec parsec(t, name :: atom) :: t
  @spec parsec({module, function_name :: atom}) :: t
  @spec parsec(t, {module, function_name :: atom}) :: t
  def parsec(combinator \\ empty(), name)

  def parsec(combinator, name) when is_combinator(combinator) and is_atom(name) do
    [{:parsec, name} | combinator]
  end

  def parsec(combinator, {module, function})
      when is_combinator(combinator) and is_atom(module) and is_atom(function) do
    [{:parsec, {module, function}} | combinator]
  end

  @doc ~S"""
  Defines a single ASCII codepoint in the given ranges.

  `ranges` is a list containing one of:

    * a `min..max` range expressing supported codepoints
    * a `codepoint` integer expressing a supported codepoint
    * `{:not, min..max}` expressing not supported codepoints
    * `{:not, codepoint}` expressing a not supported codepoint

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :digit_and_lowercase,
                  empty()
                  |> ascii_char([?0..?9])
                  |> ascii_char([?a..?z])
      end

      MyParser.digit_and_lowercase("1a")
      #=> {:ok, [?1, ?a], "", %{}, {1, 0}, 2}

      MyParser.digit_and_lowercase("a1")
      #=> {:error, "expected ASCII character in the range '0' to '9', followed by ASCII character in the range 'a' to 'z'", "a1", %{}, {1, 0}, 0}

  """
  @spec ascii_char([range]) :: t
  @spec ascii_char(t, [range]) :: t
  def ascii_char(combinator \\ empty(), ranges)
      when is_combinator(combinator) and is_list(ranges) do
    {inclusive, exclusive} = split_ranges!(ranges, "ascii_char")
    bin_segment(combinator, inclusive, exclusive, :integer)
  end

  @doc ~S"""
  Defines a single UTF-8 codepoint in the given ranges.

  `ranges` is a list containing one of:

    * a `min..max` range expressing supported codepoints
    * a `codepoint` integer expressing a supported codepoint
    * `{:not, min..max}` expressing not supported codepoints
    * `{:not, codepoint}` expressing a not supported codepoint

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :digit_and_utf8,
                  empty()
                  |> utf8_char([?0..?9])
                  |> utf8_char([])
      end

      MyParser.digit_and_utf8("1é")
      #=> {:ok, [?1, ?é], "", %{}, {1, 0}, 2}

      MyParser.digit_and_utf8("a1")
      #=> {:error, "expected utf8 codepoint in the range '0' to '9', followed by utf8 codepoint", "a1", %{}, {1, 0}, 0}

  """
  @spec utf8_char([range]) :: t
  @spec utf8_char(t, [range]) :: t
  def utf8_char(combinator \\ empty(), ranges)
      when is_combinator(combinator) and is_list(ranges) do
    {inclusive, exclusive} = split_ranges!(ranges, "utf8_char")
    bin_segment(combinator, inclusive, exclusive, :utf8)
  end

  @doc ~S"""
  Adds a label to the combinator to be used in error reports.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :digit_and_lowercase,
                  empty()
                  |> ascii_char([?0..?9])
                  |> ascii_char([?a..?z])
                  |> label("digit followed by lowercase letter")
      end

      MyParser.digit_and_lowercase("1a")
      #=> {:ok, [?1, ?a], "", %{}, {1, 0}, 2}

      MyParser.digit_and_lowercase("a1")
      #=> {:error, "expected a digit followed by lowercase letter", "a1", %{}, {1, 0}, 0}

  """
  @spec label(t, String.t()) :: t
  @spec label(t, t, String.t()) :: t
  def label(combinator \\ empty(), to_label, label)
      when is_combinator(combinator) and is_combinator(to_label) and is_binary(label) do
    non_empty!(to_label, "label")
    [{:label, Enum.reverse(to_label), label} | combinator]
  end

  @doc ~S"""
  Defines an integer combinator with exact length or `min` and `max`
  length.

  If you want an integer of unknown size, use `integer(min: 1)`.

  This combinator does not parse the sign and is always on base 10.

  ## Examples

  With exact length:

      defmodule MyParser do
        import NimbleParsec

        defparsec :two_digits_integer, integer(2)
      end

      MyParser.two_digits_integer("123")
      #=> {:ok, [12], "3", %{}, {1, 0}, 2}

      MyParser.two_digits_integer("1a3")
      #=> {:error, "expected ASCII character in the range '0' to '9', followed by ASCII character in the range '0' to '9'", "1a3", %{}, {1, 0}, 0}

  With min and max:

      defmodule MyParser do
        import NimbleParsec

        defparsec :two_digits_integer, integer(min: 2, max: 4)
      end

      MyParser.two_digits_integer("123")
      #=> {:ok, [123], "", %{}, {1, 0}, 2}

      MyParser.two_digits_integer("1a3")
      #=> {:error, "expected ASCII character in the range '0' to '9', followed by ASCII character in the range '0' to '9'", "1a3", %{}, {1, 0}, 0}

  If the size of the integer has a min and max close to each other, such as
  from 2 to 4 or from 1 to 2, using choice may emit more efficient code:

      choice([integer(4), integer(3), integer(2)])

  Note you should start from bigger to smaller.
  """
  @spec integer(pos_integer | [min_and_max]) :: t
  @spec integer(t, pos_integer | [min_and_max]) :: t
  def integer(combinator \\ empty(), count_or_opts)

  def integer(combinator, count)
      when is_combinator(combinator) and is_integer(count) do
    validate_min_and_max!(count, 1)

    min_max_compile_runtime_chars(
      combinator,
      ascii_char([?0..?9]),
      count,
      :__compile_integer__,
      :__runtime_integer__,
      []
    )
  end

  def integer(combinator, opts)
      when is_combinator(combinator) and is_list(opts) do
    # Read the minimum and maximum value to ensure the presence of at least one character
    {min_val, max_val} = validate_min_and_max!(opts, 1)
    opts = opts |> Keyword.put(:min, min_val) |> Keyword.put(:max, max_val)

    min_max_compile_runtime_chars(
      combinator,
      ascii_char([?0..?9]),
      opts,
      :__compile_integer__,
      :__runtime_integer__,
      []
    )
  end

  @doc ~S"""
  Defines an ASCII string combinator with an exact length or `min` and `max`
  length.

  The `ranges` specify the allowed characters in the ASCII string.
  See `ascii_char/2` for more information.

  If you want a string of unknown size, use `ascii_string(ranges, min: 1)`.
  If you want a literal string, use `string/2`.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :two_lowercase_letters, ascii_string([?a..?z], 2)
      end

      MyParser.two_lowercase_letters("abc")
      #=> {:ok, ["ab"], "c", %{}, {1, 0}, 2}

  """
  @spec ascii_string([range], pos_integer | [min_and_max]) :: t
  @spec ascii_string(t, [range], pos_integer | [min_and_max]) :: t
  def ascii_string(combinator \\ empty(), range, count_or_opts)
      when is_combinator(combinator) and is_list(range) and
             (is_integer(count_or_opts) or is_list(count_or_opts)) do
    min_max_compile_runtime_chars(
      combinator,
      ascii_char(range),
      count_or_opts,
      :__compile_string__,
      :__runtime_string__,
      [quote(do: integer)]
    )
  end

  @doc ~S"""
  Defines an UTF8 string combinator with of exact length or `min` and `max`
  codepoint length.

  The `ranges` specify the allowed characters in the UTF8 string.
  See `utf8_char/2` for more information.

  If you want a string of unknown size, use `utf8_string(ranges, min: 1)`.
  If you want a literal string, use `string/2`.

  Note that the combinator matches on codepoints, not graphemes. Therefore
  results may vary depending on whether the input is in `nfc` or `nfd`
  normalized form.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :two_letters, utf8_string([], 2)
      end

      MyParser.two_letters("áé")
      #=> {:ok, ["áé"], "", %{}, {1, 0}, 3}

  """
  @spec utf8_string([range], pos_integer | [min_and_max]) :: t
  @spec utf8_string(t, [range], pos_integer | [min_and_max]) :: t
  def utf8_string(combinator \\ empty(), range, count_or_opts)
      when is_combinator(combinator) and is_list(range) and
             (is_integer(count_or_opts) or is_list(count_or_opts)) do
    min_max_compile_runtime_chars(
      combinator,
      utf8_char(range),
      count_or_opts,
      :__compile_string__,
      :__runtime_string__,
      [quote(do: utf8)]
    )
  end

  @doc ~S"""
  Defines an end of string combinator.

  The end of string does not produce a token and can be parsed multiple times.
  This function is useful to avoid having to check for an empty remainder after
  a successful parse.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :letter_pairs, utf8_string([], 2) |> repeat() |> eos()
      end

      MyParser.letter_pairs("hi")
      #=> {:ok, ["hi"], "", %{}, {1, 0}, 2}

      MyParser.letter_pairs("hello")
      #=> {:error, "expected end of string", "o", %{}, {1, 0}, 4}
  """
  @spec eos :: t
  @spec eos(t) :: t
  def eos(combinator \\ empty()) do
    [:eos | combinator]
  end

  @doc ~S"""
  Concatenates two combinators.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :digit_upper_lower_plus,
                  concat(
                    concat(ascii_char([?0..?9]), ascii_char([?A..?Z])),
                    concat(ascii_char([?a..?z]), ascii_char([?+..?+]))
                  )
      end

      MyParser.digit_upper_lower_plus("1Az+")
      #=> {:ok, [?1, ?A, ?z, ?+], "", %{}, {1, 0}, 4}

  """
  @spec concat(t, t) :: t
  def concat(left, right) when is_combinator(left) and is_combinator(right) do
    right ++ left
  end

  @doc """
  Duplicates the combinator `to_duplicate` `n` times.
  """
  @spec duplicate(t, non_neg_integer) :: t
  @spec duplicate(t, t, non_neg_integer) :: t
  def duplicate(combinator \\ empty(), to_duplicate, n)

  def duplicate(combinator, to_duplicate, 0)
      when is_combinator(combinator) and is_combinator(to_duplicate) do
    combinator
  end

  def duplicate(combinator, to_duplicate, n)
      when is_combinator(combinator) and is_combinator(to_duplicate) and is_integer(n) and n >= 1 do
    Enum.reduce(1..n, combinator, fn _, acc -> to_duplicate ++ acc end)
  end

  @doc """
  Puts the result of the given combinator as the first element
  of a tuple with the `byte_offset` as second element.

  `byte_offset` is a non-negative integer.
  """
  @spec byte_offset(t) :: t
  @spec byte_offset(t, t) :: t
  def byte_offset(combinator \\ empty(), to_wrap)
      when is_combinator(combinator) and is_combinator(to_wrap) do
    quoted_post_traverse(combinator, to_wrap, {__MODULE__, :__byte_offset__, []})
  end

  @doc """
  Puts the result of the given combinator as the first element
  of a tuple with the `line` as second element.

  `line` is a tuple where the first element is the current line
  and the second element is the byte offset immediately after
  the newline.
  """
  @spec line(t) :: t
  @spec line(t, t) :: t
  def line(combinator \\ empty(), to_wrap)
      when is_combinator(combinator) and is_combinator(to_wrap) do
    quoted_post_traverse(combinator, to_wrap, {__MODULE__, :__line__, []})
  end

  @doc ~S"""
  Traverses the combinator results with the remote or local function `call`.

  `call` is either a `{module, function, args}` representing
  a remote call, a `{function, args}` representing a local call
  or an atom `function` representing `{function, []}`.

  The function given in `call` will receive 5 additional arguments.
  The rest of the parsed binary, the parser results to be post_traversed,
  the parser context, the current line and the current offset will
  be prepended to the given `args`. The `args` will be injected at
  the compile site and therefore must be escapable via `Macro.escape/1`.

  The line and offset will represent the location after the combinators.
  To retrieve the position before the combinators, use `pre_traverse/3`.

  The `call` must return a tuple `{rest, acc, context}` with list of
  results to be added to the accumulator as first argument and a context
  as second argument. It may also return `{:error, reason}` to stop
  processing. Notice the received results are in reverse order and
  must be returned in reverse order too.

  The number of elements returned does not need to be
  the same as the number of elements given.

  This is a low-level function for changing the parsed result.
  On top of this function, other functions are built, such as
  `map/3` if you want to map over each individual element and
  not worry about ordering, `reduce/3` to reduce all elements
  into a single one, `replace/3` if you want to replace the
  parsed result by a single value and `ignore/2` if you want to
  ignore the parsed result.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :letters_to_chars,
                  ascii_char([?a..?z])
                  |> ascii_char([?a..?z])
                  |> ascii_char([?a..?z])
                  |> post_traverse({:join_and_wrap, ["-"]})

        defp join_and_wrap(rest, args, context, _line, _offset, joiner) do
          {rest, args |> Enum.join(joiner) |> List.wrap(), context}
        end
      end

      MyParser.letters_to_chars("abc")
      #=> {:ok, ["99-98-97"], "", %{}, {1, 0}, 3}

  """
  @spec post_traverse(t, call) :: t
  @spec post_traverse(t, t, call) :: t
  def post_traverse(combinator \\ empty(), to_post_traverse, call)
      when is_combinator(combinator) and is_combinator(to_post_traverse) do
    compile_call!([], call, "post_traverse")
    quoted_post_traverse(combinator, to_post_traverse, {__MODULE__, :__post_traverse__, [call]})
  end

  @doc """
  The same as `post_traverse/3` but receives the line and offset
  from before the wrapped combinators.

  `post_traverse/3` should be preferred as it keeps less stack
  information. Use `pre_traverse/3` only if you have to access
  the line and offset from before the given combinators.
  """
  @spec pre_traverse(t, call) :: t
  @spec pre_traverse(t, t, call) :: t
  def pre_traverse(combinator \\ empty(), to_pre_traverse, call)
      when is_combinator(combinator) and is_combinator(to_pre_traverse) do
    compile_call!([], call, "pre_traverse")
    quoted_pre_traverse(combinator, to_pre_traverse, {__MODULE__, :__pre_traverse__, [call]})
  end

  @doc ~S"""
  Checks if a combinator is ahead.

  If it succeeds, it continues as usual, otherwise it aborts the
  closest `choice/2`, `repeat/2`, etc. If there is no closest
  operation to abort, then it errors.

  Note a lookahead never changes the accumulated output nor the
  context.

  ## Examples

  For example, imagine you want to parse a language that has the
  keywords "if" and "while" and identifiers made of any letters or
  number, where keywords and identifiers can be separated by a
  single white space:

      defmodule IfWhileLang do
        import NimbleParsec

        keyword =
          choice([
            string("if") |> replace(:if),
            string("while") |> replace(:while)
          ])

        identifier =
          ascii_string([?a..?z, ?A..?Z, ?0..?9], min: 1)

        defparsec :expr, repeat(choice([keyword, identifier]) |> optional(string(" ")))
      end

  The issue with the implementation above is that the following
  will parse:

      IfWhileLang.expr("iffy")
      {:ok, [:if, "fy"], "", %{}, {1, 0}, 4}

  However, "iffy" should be treated as a full identifier. We could
  solve this by inverting the order of `keyword` and `identifier`
  in `:expr` but that means "if" itself will be considered an identifier
  and not a keyword. To solve this, we need lookaheads.

  One option is to check that after the keyword we either have an
  empty string OR the end of the string:

      keyword =
        choice([
          string("if") |> replace(:if),
          string("while") |> replace(:while)
        ])
        |> lookahead(choice([string(" "), eos()]))

  However, in this case, a negative lookahead may be clearer,
  and we can assert that we don't have any identifier character after
  the keyword:

      keyword =
        choice([
          string("if") |> replace(:if),
          string("while") |> replace(:while)
        ])
        |> lookahead_not(ascii_char([?a..?z, ?A..?Z, ?0..?9]))

  Now we get the desired result back:

      IfWhileLang.expr("iffy")
      #=> {:ok, ["iffy"], "", %{}, {1, 0}, 4}

      IfWhileLang.expr("if fy")
      #=> {:ok, [:if, " ", "fy"], "", %{}, {1, 0}, 5}

  """
  @spec lookahead(t) :: t
  @spec lookahead(t, t) :: t
  def lookahead(combinator \\ empty(), to_lookahead)
      when is_combinator(combinator) and is_combinator(to_lookahead) do
    [{:lookahead, Enum.reverse(to_lookahead), :positive} | combinator]
  end

  @doc ~S"""
  Checks if a combinator is not ahead.

  If it succeeds, it aborts the closest `choice/2`, `repeat/2`, etc.
  Otherwise it continues as usual. If there is no closest operation
  to abort, then it errors.

  Note a lookahead never changes the accumulated output nor the
  context.

  For an example, see `lookahead/2`.
  """
  @spec lookahead_not(t) :: t
  @spec lookahead_not(t, t) :: t
  def lookahead_not(combinator \\ empty(), to_lookahead)
      when is_combinator(combinator) and is_combinator(to_lookahead) do
    [{:lookahead, Enum.reverse(to_lookahead), :negative} | combinator]
  end

  @doc """
  Invokes `call` to emit the AST that post traverses the `to_post_traverse`
  combinator results.

  This is similar to `post_traverse/3`. In `post_traverse/3`, `call` is
  invoked to process the combinator results. In here, it is invoked to
  emit AST that in its turn will process the combinator results.
  The invoked function must return the same types as `post_traverse/3`.

  `call` is a `{module, function, args}` and it will receive 5
  additional arguments. The AST representation of the rest of the
  parsed binary, the parser results, context, line and offset will
  be prepended to `args`. `call` is invoked at compile time and is
  useful in combinators that avoid injecting runtime dependencies.

  The line and offset will represent the location after the combinators.
  To retrieve the position before the combinators, use `quoted_pre_traverse/3`.

  This function must be used only when you want to emit code that
  has no runtime dependencies in other modules. In most cases,
  using `post_traverse/3` is better, since it doesn't work on ASTs
  and instead works at runtime.
  """
  @spec quoted_post_traverse(t, mfargs) :: t
  @spec quoted_post_traverse(t, t, mfargs) :: t
  def quoted_post_traverse(combinator \\ empty(), to_post_traverse, {_, _, _} = call)
      when is_combinator(combinator) and is_combinator(to_post_traverse) do
    quoted_traverse(combinator, to_post_traverse, :post, call)
  end

  @doc """
  The same as `quoted_post_traverse/3` but receives the line and offset
  from before the wrapped combinators.

  `quoted_post_traverse/3` should be preferred as it keeps less stack
  information. Use `quoted_pre_traverse/3` only if you have to access
  the line and offset from before the given combinators.
  """
  @spec quoted_pre_traverse(t, mfargs) :: t
  @spec quoted_pre_traverse(t, t, mfargs) :: t
  def quoted_pre_traverse(combinator \\ empty(), to_pre_traverse, {_, _, _} = call)
      when is_combinator(combinator) and is_combinator(to_pre_traverse) do
    quoted_traverse(combinator, to_pre_traverse, :pre, call)
  end

  @doc ~S"""
  Maps over the combinator results with the remote or local function in `call`.

  `call` is either a `{module, function, args}` representing
  a remote call, a `{function, args}` representing a local call
  or an atom `function` representing `{function, []}`.

  Each parser result will be invoked individually for the `call`.
  Each result be prepended to the given `args`. The `args` will
  be injected at the compile site and therefore must be escapable
  via `Macro.escape/1`.

  See `post_traverse/3` for a low level version of this function.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :letters_to_string_chars,
                  ascii_char([?a..?z])
                  |> ascii_char([?a..?z])
                  |> ascii_char([?a..?z])
                  |> map({Integer, :to_string, []})
      end

      MyParser.letters_to_string_chars("abc")
      #=> {:ok, ["97", "98", "99"], "", %{}, {1, 0}, 3}
  """
  @spec map(t, call) :: t
  @spec map(t, t, call) :: t
  def map(combinator \\ empty(), to_map, call)
      when is_combinator(combinator) and is_combinator(to_map) do
    var = Macro.var(:var, __MODULE__)
    call = compile_call!([var], call, "map")
    quoted_post_traverse(combinator, to_map, {__MODULE__, :__map__, [var, call]})
  end

  @doc ~S"""
  Reduces over the combinator results with the remote or local function in `call`.

  `call` is either a `{module, function, args}` representing
  a remote call, a `{function, args}` representing a local call
  or an atom `function` representing `{function, []}`.

  The parser results to be reduced will be prepended to the
  given `args`. The `args` will be injected at the compile site
  and therefore must be escapable via `Macro.escape/1`.

  See `post_traverse/3` for a low level version of this function.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :letters_to_reduced_chars,
                  ascii_char([?a..?z])
                  |> ascii_char([?a..?z])
                  |> ascii_char([?a..?z])
                  |> reduce({Enum, :join, ["-"]})
      end

      MyParser.letters_to_reduced_chars("abc")
      #=> {:ok, ["97-98-99"], "", %{}, {1, 0}, 3}
  """
  @spec reduce(t, call) :: t
  @spec reduce(t, t, call) :: t
  def reduce(combinator \\ empty(), to_reduce, call)
      when is_combinator(combinator) and is_combinator(to_reduce) do
    compile_call!([], call, "reduce")
    quoted_post_traverse(combinator, to_reduce, {__MODULE__, :__reduce__, [call]})
  end

  @doc """
  Wraps the results of the given combinator in `to_wrap` in a list.
  """
  @spec wrap(t) :: t
  @spec wrap(t, t) :: t
  def wrap(combinator \\ empty(), to_wrap)
      when is_combinator(combinator) and is_combinator(to_wrap) do
    quoted_post_traverse(combinator, to_wrap, {__MODULE__, :__wrap__, []})
  end

  @doc """
  Tags the result of the given combinator in `to_tag` in a tuple with
  `tag` as first element.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :integer, integer(min: 1) |> tag(:integer)
      end

      MyParser.integer("1234")
      #=> {:ok, [integer: [1234]], "", %{}, {1, 0}, 4}

  Notice, however, that the integer result is wrapped in a list, because
  the parser is expected to emit multiple tokens. When you are sure that
  only a single token is emitted, you should use `unwrap_and_tag/3`.
  """
  @spec tag(t, term) :: t
  @spec tag(t, t, term) :: t
  def tag(combinator \\ empty(), to_tag, tag)
      when is_combinator(combinator) and is_combinator(to_tag) do
    quoted_post_traverse(combinator, to_tag, {__MODULE__, :__tag__, [Macro.escape(tag)]})
  end

  @doc """
  Unwraps and tags the result of the given combinator in `to_tag` in a tuple with
  `tag` as first element.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :integer, integer(min: 1) |> unwrap_and_tag(:integer)
      end

      MyParser.integer("1234")
      #=> {:ok, [integer: 1234], "", %{}, {1, 0}, 4}


  In case the combinator emits greater than one token, an error will be raised.
  See `tag/3` for more information.
  """
  @spec unwrap_and_tag(t, term) :: t
  @spec unwrap_and_tag(t, t, term) :: t
  def unwrap_and_tag(combinator \\ empty(), to_tag, tag)
      when is_combinator(combinator) and is_combinator(to_tag) do
    quoted_post_traverse(
      combinator,
      to_tag,
      {__MODULE__, :__unwrap_and_tag__, [Macro.escape(tag)]}
    )
  end

  @doc """
  Inspects the combinator state given to `to_debug` with the given `opts`.
  """
  @spec debug(t) :: t
  @spec debug(t, t) :: t
  def debug(combinator \\ empty(), to_debug)
      when is_combinator(combinator) and is_combinator(to_debug) do
    quoted_pre_traverse(combinator, to_debug, {__MODULE__, :__debug__, []})
  end

  @doc ~S"""
  Defines a string binary value.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :string_t, string("T")
      end

      MyParser.string_t("T")
      #=> {:ok, ["T"], "", %{}, {1, 0}, 1}

      MyParser.string_t("not T")
      #=> {:error, "expected a string \"T\"", "not T", %{}, {1, 0}, 0}

  """
  @spec string(binary) :: t
  @spec string(t, binary) :: t
  def string(combinator \\ empty(), binary)
      when is_combinator(combinator) and is_binary(binary) do
    [{:string, binary} | combinator]
  end

  @doc """
  Ignores the output of combinator given in `to_ignore`.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :ignorable, string("T") |> ignore() |> integer(2)
      end

      MyParser.ignorable("T12")
      #=> {:ok, [12], "", %{}, {1, 0}, 2}

  """
  @spec ignore(t) :: t
  @spec ignore(t, t) :: t
  def ignore(combinator \\ empty(), to_ignore)
      when is_combinator(combinator) and is_combinator(to_ignore) do
    if to_ignore == empty() do
      to_ignore
    else
      quoted_constant_traverse(combinator, to_ignore, {__MODULE__, :__constant__, [[]]})
    end
  end

  @doc """
  Replaces the output of combinator given in `to_replace` by a single value.

  The `value` will be injected at the compile site
  and therefore must be escapable via `Macro.escape/1`.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :replaceable, string("T") |> replace("OTHER") |> integer(2, 2)
      end

      MyParser.replaceable("T12")
      #=> {:ok, ["OTHER", 12], "", %{}, {1, 0}, 2}

  """
  @spec replace(t, term) :: t
  @spec replace(t, t, term) :: t
  def replace(combinator \\ empty(), to_replace, value)
      when is_combinator(combinator) and is_combinator(to_replace) do
    value = Macro.escape(value)
    quoted_constant_traverse(combinator, to_replace, {__MODULE__, :__constant__, [[value]]})
  end

  @doc """
  Allows the combinator given on `to_repeat` to appear zero or more times.

  Beware! Since `repeat/2` allows zero entries, it cannot be used inside
  `choice/2`, because it will always succeed and may lead to unused function
  warnings since any further choice won't ever be attempted. For example,
  because `repeat/2` always succeeds, the `string/2` combinator below it
  won't ever run:

      choice([
        repeat(ascii_char([?a..?z])),
        string("OK")
      ])

  Instead of `repeat/2`, you may want to use `times/3` with the flags `:min`
  and `:max`.

  Also beware! If you attempt to repeat a combinator that can match nothing,
  like `optional/2`, `repeat/2` will not terminate. For example, consider
  this combinator:

       repeat(optional(utf8_char([?a])))

  This combinator will never terminate because `repeat/2` chooses the empty
  option of `optional/2` every time. Since the goal of the parser above is
  to parse 0 or more `?a` characters, it can be represented by
  `repeat(utf8_char([?a]))`, because `repeat/2` allows 0 or more matches.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :repeat_lower, repeat(ascii_char([?a..?z]))
      end

      MyParser.repeat_lower("abcd")
      #=> {:ok, [?a, ?b, ?c, ?d], "", %{}, {1, 0}, 4}

      MyParser.repeat_lower("1234")
      #=> {:ok, [], "1234", %{}, {1, 0}, 0}

  """
  @spec repeat(t) :: t
  @spec repeat(t, t) :: t
  @spec repeat(t, opts) :: t
  @spec repeat(t, t, opts) :: t
  def repeat(combinator \\ empty(), to_repeat, opts \\ [])
      when is_combinator(combinator) and is_combinator(to_repeat) and is_list(opts) do
    non_empty!(to_repeat, "repeat")
    quoted_repeat_while(combinator, to_repeat, {__MODULE__, :__cont_context__, []}, opts)
  end

  @doc """
  Marks the given combinator should appear eventually.

  Any other data before the combinator appears is discarded.
  If the combinator never appears, then it is an error.

  **Note:** this can be potentially a very expensive operation
  as it executes the given combinator byte by byte until finding
  an eventual match or ultimately failing. For example, if you
  are looking for an integer, it is preferable to discard
  everything that is not an integer

      ignore(ascii_string([not: ?0..?9]))

  rather than eventually look for an integer

      eventually(ascii_string([?0..?9]))

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        hour = integer(min: 1, max: 2)
        defparsec :extract_hour, eventually(hour)
      end

      MyParser.extract_hour("let's meet at 12?")
      #=> {:ok, [12], "?", %{}, {1, 0}, 16}

  """
  @spec eventually(t) :: t
  @spec eventually(t, t) :: t
  def eventually(combinator \\ empty(), eventually)
      when is_combinator(combinator) and is_combinator(eventually) do
    non_empty!(eventually, "eventually")
    [{:eventually, Enum.reverse(eventually)} | combinator]
  end

  @doc ~S"""
  Repeats while the given remote or local function `while` returns
  `{:cont, context}`.

  If the combinator `to_repeat` stops matching, then the whole repeat
  loop stops successfully, hence it is important to assert the terminated
  value after repeating.

  In case repetition should stop, `while` must return `{:halt, context}`.

  `while` is either a `{module, function, args}` representing
  a remote call, a `{function, args}` representing a local call
  or an atom `function` representing `{function, []}`.

  The function given in `while` will receive 4 additional arguments.
  The `rest` of the binary to be parsed, the parser context, the
  current line and the current offset will be prepended to the
  given `args`. The `args` will be injected at the compile site
  and therefore must be escapable via `Macro.escape/1`.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :string_with_quotes,
                  ascii_char([?"])
                  |> repeat_while(
                    choice([
                      ~S(\") |> string() |> replace(?"),
                      utf8_char([])
                    ]),
                    {:not_quote, []}
                  )
                  |> ascii_char([?"])
                  |> reduce({List, :to_string, []})

        defp not_quote(<<?", _::binary>>, context, _, _), do: {:halt, context}
        defp not_quote(_, context, _, _), do: {:cont, context}
      end

      MyParser.string_with_quotes(~S("string with quotes \" inside"))
      {:ok, ["\"string with quotes \" inside\""], "", %{}, {1, 0}, 30}

  Note you can use `lookahead/2` and `lookahead_not/2` with
  `repeat/2` (instead of `repeat_while/3`) to write a combinator
  that repeats while a combinator matches (or does not match).
  For example, the same combinator above could be written as:

      defmodule MyParser do
        import NimbleParsec

        defparsec :string_with_quotes,
                  ascii_char([?"])
                  |> repeat(
                    lookahead_not(ascii_char([?"]))
                    |> choice([
                      ~S(\") |> string() |> replace(?"),
                      utf8_char([])
                    ])
                  )
                  |> ascii_char([?"])
                  |> reduce({List, :to_string, []})
      end

      MyParser.string_with_quotes(~S("string with quotes \" inside"))
      {:ok, ["\"string with quotes \" inside\""], "", %{}, {1, 0}, 30}

  However, `repeat_while` is still useful when the condition to
  repeat comes from the context passed around.
  """
  @spec repeat_while(t, call) :: t
  @spec repeat_while(t, t, call) :: t
  @spec repeat_while(t, t, call, opts) :: t
  def repeat_while(combinator \\ empty(), to_repeat, while, opts \\ [])
      when is_combinator(combinator) and is_combinator(to_repeat) and is_list(opts) do
    non_empty!(to_repeat, "repeat_while")
    compile_call!([], while, "repeat_while")
    quoted_repeat_while(combinator, to_repeat, {__MODULE__, :__repeat_while__, [while]}, opts)
  end

  @doc """
  Invokes `while` to emit the AST that will repeat `to_repeat`
  while the AST code returns `{:cont, context}`.

  In case repetition should stop, `while` must return `{:halt, context}`.

  `while` is a `{module, function, args}` and it will receive 4
  additional arguments. The AST representations of the binary to be
  parsed, context, line and offset will be prepended to `args`. `while`
  is invoked at compile time and is useful in combinators that avoid
  injecting runtime dependencies.
  """
  @spec quoted_repeat_while(t, mfargs) :: t
  @spec quoted_repeat_while(t, t, mfargs) :: t
  @spec quoted_repeat_while(t, t, mfargs, opts) :: t
  def quoted_repeat_while(combinator \\ empty(), to_repeat, {_, _, _} = while, opts \\ [])
      when is_combinator(combinator) and is_combinator(to_repeat) and is_list(opts) do
    non_empty!(to_repeat, "quoted_repeat_while")
    [{:repeat, Enum.reverse(to_repeat), while, opts[:gen_times]} | combinator]
  end

  @doc """
  Allow the combinator given on `to_repeat` to appear at least, at most
  or exactly a given amount of times.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :minimum_lower, times(ascii_char([?a..?z]), min: 2)
      end

      MyParser.minimum_lower("abcd")
      #=> {:ok, [?a, ?b, ?c, ?d], "", %{}, {1, 0}, 4}

      MyParser.minimum_lower("ab12")
      #=> {:ok, [?a, ?b], "12", %{}, {1, 0}, 2}

      MyParser.minimum_lower("a123")
      #=> {:ok, [], "a123", %{}, {1, 0}, 0}

  """
  @spec times(t, pos_integer | [min_and_max]) :: t
  @spec times(t, t, pos_integer | [min_and_max]) :: t
  def times(combinator \\ empty(), to_repeat, count_or_min_max)

  def times(combinator, to_repeat, n)
      when is_combinator(combinator) and is_combinator(to_repeat) and is_integer(n) and n >= 1 do
    non_empty!(to_repeat, "times")
    duplicate(combinator, to_repeat, n)
  end

  def times(combinator, to_repeat, opts)
      when is_combinator(combinator) and is_combinator(to_repeat) and is_list(opts) do
    {min, max} = validate_min_and_max!(opts)
    non_empty!(to_repeat, "times")

    combinator =
      if min > 0 do
        duplicate(combinator, to_repeat, min)
      else
        combinator
      end

    to_repeat = Enum.reverse(to_repeat)

    combinator =
      if max do
        [{:times, to_repeat, max - min} | combinator]
      else
        [{:repeat, to_repeat, {__MODULE__, :__cont_context__, []}, opts[:gen_times]} | combinator]
      end

    combinator
  end

  @doc """
  Chooses one of the given combinators.

  Expects at least two choices.

  ## Beware! Char combinators

  Note both `utf8_char/2` and `ascii_char/2` allow multiple ranges to
  be given. Therefore, instead this:

      choice([
        ascii_char([?a..?z]),
        ascii_char([?A..?Z]),
      ])

  One should simply prefer:

      ascii_char([?a..?z, ?A..?Z])

  As the latter is compiled more efficiently by `NimbleParsec`.

  ## Beware! Always successful combinators

  If a combinator that always succeeds is given as a choice, that choice
  will always succeed which may lead to unused function warnings since
  any further choice won't ever be attempted. For example, because `repeat/2`
  always succeeds, the `string/2` combinator below it won't ever run:

      choice([
        repeat(ascii_char([?0..?9])),
        string("OK")
      ])

  Instead of `repeat/2`, you may want to use `times/3` with the flags `:min`
  and `:max`.

  ## Beware! Overlapping choices

  In case choices overlap, there is no guarantee which error will be the one
  effectively returned. For example, imagine this choice:

      choice([
        string("<abc>foo</abc>"),
        string("<abc>")
      ]

  Since both choices can be activated for an input starting with "abc",
  NimbleParsec guarantees it will return the error from one of them, but
  not which.
  """
  @spec choice(nonempty_list(t)) :: t
  @spec choice(t, nonempty_list(t)) :: t
  @spec choice(t, nonempty_list(t), opts) :: t
  def choice(combinator \\ empty(), [_, _ | _] = choices, opts \\ [])
      when is_combinator(combinator) do
    choices = Enum.map(choices, &Enum.reverse/1)
    weights = opts[:gen_weights]

    if weights && length(weights) != length(choices) do
      raise ArgumentError, ":gen_weights must be a list of the same size as choices"
    end

    [{:choice, choices, weights} | combinator]
  end

  @doc """
  Marks the given combinator as `optional`.

  It is equivalent to `choice([combinator, empty()])`.
  """
  @spec optional(t) :: t
  @spec optional(t, t) :: t
  def optional(combinator \\ empty(), optional) do
    choice(combinator, [optional, empty()])
  end

  @doc """
  Defines a combinator to consume the next `n` bytes from the input.

  ## Examples

        defmodule MyParser do
          import NimbleParsec

          defparsec :three_bytes, bytes(3)
        end

        MyParser.three_bytes("abc")
        #=> {:ok, ["abc"], "", %{}, {1, 0}, 3}

        MyParser.three_bytes("ab")
        #=> {:error, "expected 3 bytes", "ab", %{}, {1, 0}, 0}
  """
  @spec bytes(pos_integer) :: t
  @spec bytes(t, pos_integer) :: t
  def bytes(combinator \\ empty(), count)
      when is_combinator(combinator) and is_integer(count) and count > 0 do
    [{:bytes, count} | combinator]
  end

  ## Helpers

  defp validate_min_and_max!(count_or_opts, required_min \\ 0)

  defp validate_min_and_max!(count, required_min)
       when is_integer(count) do
    validate_min_and_max!([min: count], required_min)
  end

  defp validate_min_and_max!(opts, required_min) do
    min = opts[:min]
    max = opts[:max]

    cond do
      min && max ->
        validate_min_or_max!(:min, min, required_min)
        validate_min_or_max!(:max, max, 1)

        max <= min and
          raise ArgumentError,
                "expected :max to be strictly greater than :min, got: #{min} and #{max}"

      min ->
        validate_min_or_max!(:min, min, required_min)

      max ->
        validate_min_or_max!(:max, max, 1)

      true ->
        raise ArgumentError, "expected :min or :max to be given"
    end

    {min || required_min, max}
  end

  defp validate_min_or_max!(kind, value, min) do
    unless is_integer(value) and value >= min do
      raise ArgumentError,
            "expected #{kind} to be an integer greater than or equal to #{min}, " <>
              "got: #{inspect(value)}"
    end
  end

  defp split_ranges!(ranges, context) do
    Enum.split_with(ranges, &split_range!(&1, context))
  end

  defp split_range!(x, _context) when is_integer(x), do: true
  defp split_range!(_.._//step, _context) when abs(step) == 1, do: true
  defp split_range!({:not, x}, _context) when is_integer(x), do: false
  defp split_range!({:not, _.._//step}, _context) when abs(step) == 1, do: false

  defp split_range!(range, context) do
    raise ArgumentError, "unknown range #{inspect(range)} given to #{context}"
  end

  defp compile_call!(extra, {module, function, args}, _context)
       when is_atom(module) and is_atom(function) and is_list(args) do
    quote do
      unquote(module).unquote(function)(
        unquote_splicing(extra),
        unquote_splicing(Macro.escape(args))
      )
    end
  end

  defp compile_call!(extra, {function, args}, _context)
       when is_atom(function) and is_list(args) do
    quote do
      unquote(function)(unquote_splicing(extra), unquote_splicing(Macro.escape(args)))
    end
  end

  defp compile_call!(extra, function, _context) when is_atom(function) do
    quote do
      unquote(function)(unquote_splicing(extra))
    end
  end

  defp compile_call!(_args, unknown, context) do
    raise ArgumentError, "unknown call given to #{context}, got: #{inspect(unknown)}"
  end

  defp non_empty!([], action) do
    raise ArgumentError, "cannot call #{action} on empty combinator"
  end

  defp non_empty!(combinator, action) do
    if Enum.any?(combinator, &is_list/1) do
      raise ArgumentError,
            "invalid combinator given to #{action}, got a list of combinators instead"
    end
  end

  ## Inner combinators

  defp quoted_constant_traverse(combinator, to_traverse, call) do
    case to_traverse do
      [{:traverse, inner_traverse, :constant, inner_call}] ->
        [{:traverse, inner_traverse, :constant, [call | inner_call]} | combinator]

      _ ->
        [{:traverse, Enum.reverse(to_traverse), :constant, [call]} | combinator]
    end
  end

  defp quoted_traverse(combinator, to_traverse, pre_or_pos, call) do
    [{:traverse, Enum.reverse(to_traverse), pre_or_pos, [call]} | combinator]
  end

  defp bin_segment(combinator, inclusive, exclusive, modifier) do
    [{:bin_segment, inclusive, exclusive, modifier} | combinator]
  end

  ## Traverse callbacks

  @doc false
  def __pre_traverse__(rest, acc, context, line, offset, call) do
    compile_call!([rest, acc, context, line, offset], call, "pre_traverse")
  end

  @doc false
  def __post_traverse__(rest, acc, context, line, offset, call) do
    compile_call!([rest, acc, context, line, offset], call, "post_traverse")
  end

  @doc false
  def __lookahead__(rest, _acc, context, line, offset, call) do
    compile_call!([rest, context, line, offset], call, "lookahead")
  end

  @doc false
  def __wrap__(rest, acc, context, _line, _offset) do
    {:{}, [], [rest, [reverse_now_or_later(acc)], context]}
  end

  @doc false
  def __tag__(rest, acc, context, _line, _offset, tag) do
    {:{}, [], [rest, [{tag, reverse_now_or_later(acc)}], context]}
  end

  @doc false
  def __unwrap_and_tag__(rest, acc, context, _line, _offset, tag) when is_list(acc) do
    case acc do
      [one] -> {:{}, [], [rest, [{tag, one}], context]}
      many -> raise "unwrap_and_tag/3 expected a single token, got: #{inspect(many)}"
    end
  end

  def __unwrap_and_tag__(rest, acc, context, _line, _offset, tag) do
    quoted =
      quote do
        case :lists.reverse(unquote(acc)) do
          [one] -> one
          many -> raise "unwrap_and_tag/3 expected a single token, got: #{inspect(many)}"
        end
      end

    {:{}, [], [rest, [{tag, quoted}], context]}
  end

  @doc false
  def __debug__(rest, acc, context, line, offset) do
    quote bind_quoted: [rest: rest, acc: acc, context: context, line: line, offset: offset] do
      IO.puts("""
      == DEBUG ==
      Bin: #{inspect(rest)}
      Acc: #{inspect(:lists.reverse(acc))}
      Ctx: #{inspect(context)}
      Lin: #{inspect(line)}
      Off: #{inspect(offset)}
      """)

      {rest, acc, context}
    end
  end

  @doc false
  def __constant__(rest, _acc, context, _line, _offset, constant) do
    {:{}, [], [rest, constant, context]}
  end

  @doc false
  def __line__(rest, acc, context, line, _offset) do
    {:{}, [], [rest, [{reverse_now_or_later(acc), line}], context]}
  end

  @doc false
  def __byte_offset__(rest, acc, context, _line, offset) do
    {:{}, [], [rest, [{reverse_now_or_later(acc), offset}], context]}
  end

  @doc false
  def __map__(rest, acc, context, _line, _offset, var, call) do
    ast =
      quote do
        Enum.map(unquote(acc), fn unquote(var) -> unquote(call) end)
      end

    {:{}, [], [rest, ast, context]}
  end

  @doc false
  def __reduce__(rest, acc, context, _line, _offset, call) do
    {:{}, [], [rest, [compile_call!([reverse_now_or_later(acc)], call, "reduce")], context]}
  end

  ## Repeat callbacks

  @doc false
  def __cont_context__(_rest, context, _line, _offset) do
    {:cont, context}
  end

  @doc false
  def __repeat_while__(quoted, context, line, offset, call) do
    compile_call!([quoted, context, line, offset], call, "repeat_while")
  end

  ## Chars callbacks

  defp min_max_compile_runtime_chars(combinator, to_repeat, count, compile, _runtime, args)
       when is_integer(count) and count >= 0 do
    chars = duplicate(to_repeat, count)
    quoted_post_traverse(combinator, chars, {__MODULE__, compile, [count | args]})
  end

  defp min_max_compile_runtime_chars(combinator, to_repeat, opts, compile, runtime, args)
       when is_list(opts) do
    {min, max} = validate_min_and_max!(opts)

    chars =
      if min > 0 do
        min_max_compile_runtime_chars(empty(), to_repeat, min, compile, runtime, args)
      else
        empty()
      end

    chars =
      if max do
        times(chars, to_repeat, max: max - min)
      else
        repeat(chars, to_repeat)
      end

    quoted_post_traverse(combinator, chars, {__MODULE__, runtime, [min, max | args]})
  end

  @doc false
  def __runtime_string__(rest, acc, context, _line, _offset, _min, _max, _type) do
    ast = quote(do: List.to_string(unquote(reverse_now_or_later(acc))))
    {:{}, [], [rest, [ast], context]}
  end

  @doc false
  def __compile_string__(rest, acc, context, _line, _offset, _count, type) when is_list(acc) do
    acc =
      for entry <- :lists.reverse(acc) do
        {:"::", [], [entry, type]}
      end

    {:{}, [], [rest, [{:<<>>, [], acc}], context]}
  end

  def __compile_string__(rest, acc, context, _line, _offset, _count, _type) do
    ast = quote(do: List.to_string(unquote(reverse_now_or_later(acc))))
    {:{}, [], [rest, [ast], context]}
  end

  @doc false
  def __runtime_integer__(rest, acc, context, _line, _offset, min, _max)
      when is_integer(min) and min > 0 do
    ast =
      quote do
        [head | tail] = unquote(reverse_now_or_later(acc))
        [:lists.foldl(fn x, acc -> x - ?0 + acc * 10 end, head, tail)]
      end

    {:{}, [], [rest, ast, context]}
  end

  def __runtime_integer__(rest, acc, context, _line, _offset, _min, _max) do
    ast =
      quote do
        [head | tail] = unquote(reverse_now_or_later(acc))
        [:lists.foldl(fn x, acc -> x - ?0 + acc * 10 end, head - ?0, tail)]
      end

    {:{}, [], [rest, ast, context]}
  end

  @doc false
  def __compile_integer__(rest, acc, context, _line, _offset, _count) when is_list(acc) do
    ast =
      acc
      |> quoted_ascii_to_integer(1)
      |> Enum.reduce(&{:+, [], [&2, &1]})

    {:{}, [], [rest, [ast], context]}
  end

  defp reverse_now_or_later(list) when is_list(list), do: :lists.reverse(list)
  defp reverse_now_or_later(expr), do: quote(do: :lists.reverse(unquote(expr)))

  defp quoted_ascii_to_integer([var | vars], 1) do
    [quote(do: unquote(var) - ?0) | quoted_ascii_to_integer(vars, 10)]
  end

  defp quoted_ascii_to_integer([var | vars], index) do
    [quote(do: (unquote(var) - ?0) * unquote(index)) | quoted_ascii_to_integer(vars, index * 10)]
  end

  defp quoted_ascii_to_integer([], _index) do
    []
  end
end
