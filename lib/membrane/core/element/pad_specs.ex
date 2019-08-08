defmodule Membrane.Core.Element.PadsSpecs do
  @moduledoc false
  # Functions parsing element pads specifications, generating functions and docs
  # based on them.
  alias Membrane.{Caps, Element}
  alias Membrane.Core.Element.OptionsSpecs
  alias Element.Pad
  alias Bunch.Type
  use Bunch

  @spec def_pads([{Pad.name_t(), raw_spec :: Macro.t()}], Pad.direction_t()) :: Macro.t()
  def def_pads(pads, direction) do
    pads
    |> Enum.reduce(
      quote do
      end,
      fn {name, spec}, acc ->
        pad_def = def_pad(name, direction, spec)

        quote do
          unquote(acc)
          unquote(pad_def)
        end
      end
    )
  end

  @doc """
  Returns documentation string common for both input and output pads
  """
  @spec def_pad_docs(Pad.direction_t()) :: String.t()
  def def_pad_docs(direction) do
    """
    Macro that defines #{direction} pad for the element.

    Allows to use `one_of/1` and `range/2` functions from `Membrane.Caps.Matcher`
    without module prefix.

    It automatically generates documentation from the given definition
    and adds compile-time caps specs validation.

    The type `t:Membrane.Element.Pad.#{direction}_spec_t/0` describes how the definition of pads should look.
    """
  end

  @doc """
  Returns AST inserted into element's module defining a pad
  """
  @spec def_pad(Pad.name_t(), Pad.direction_t(), Macro.t()) :: Macro.t()
  def def_pad(pad_name, direction, raw_specs) do
    Code.ensure_loaded(Caps.Matcher)

    specs =
      raw_specs
      |> Bunch.Macro.inject_calls([
        {Caps.Matcher, :one_of},
        {Caps.Matcher, :range}
      ])

    {escaped_pad_opts, pad_opts_typedef} = OptionsSpecs.def_pad_options(pad_name, specs[:options])

    specs = specs |> Keyword.put(:options, escaped_pad_opts)

    quote do
      if Module.get_attribute(__MODULE__, :membrane_pads) == nil do
        Module.register_attribute(__MODULE__, :membrane_pads, accumulate: true)
        @before_compile {unquote(__MODULE__), :generate_membrane_pads}
      end

      @membrane_pads unquote(__MODULE__).parse_pad_specs!(
                       {unquote(pad_name), unquote(specs)},
                       unquote(direction),
                       __ENV__
                     )
      unquote(pad_opts_typedef)
    end
  end

  @doc """
  Generates `membrane_pads/0` function, along with docs and typespecs.
  """
  defmacro generate_membrane_pads(env) do
    pads = Module.get_attribute(env.module, :membrane_pads) |> Enum.reverse()
    :ok = validate_pads!(pads, env)
    pads_docs = generate_docs_from_pads_specs(pads)

    alias Membrane.Element.Pad

    quote do
      @doc """
      Returns pads descriptions for `#{inspect(__MODULE__)}`
      """
      @spec membrane_pads() :: [{unquote(Pad).name_t(), unquote(Pad).description_t()}]
      def membrane_pads() do
        unquote(pads |> Macro.escape())
      end

      if @moduledoc != false do
        @moduledoc """
        #{@moduledoc}

        ## Pads

        #{unquote(pads_docs)}
        """
      end
    end
  end

  @spec validate_pads!(
          pads :: [{Pad.name_t(), Pad.description_t()}],
          env :: Macro.Env.t()
        ) :: :ok
  defp validate_pads!(pads, env) do
    with [] <- pads |> Keyword.keys() |> Bunch.Enum.duplicates() do
      :ok
    else
      dups ->
        raise CompileError, file: env.file, description: "Duplicate pad names: #{inspect(dups)}"
    end
  end

  @spec parse_pad_specs!(
          specs :: Pad.spec_t(),
          direction :: Pad.direction_t(),
          declaration_env :: Macro.Env.t()
        ) :: {Pad.name_t(), Pad.description_t()}
  def parse_pad_specs!(specs, direction, env) do
    with {:ok, specs} <- parse_pad_specs(specs, direction) do
      specs
    else
      {:error, reason} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: """
          Error parsing pad specs defined in #{inspect(env.module)}.def_#{direction}_pads/1,
          reason: #{inspect(reason)}
          """
    end
  end

  @spec parse_pad_specs(Pad.spec_t(), Pad.direction_t()) ::
          Type.try_t({Pad.name_t(), Pad.description_t()})
  def parse_pad_specs(spec, direction) do
    withl spec: {name, config} when is_atom(name) and is_list(config) <- spec,
          config:
            {:ok, config} <-
              config
              |> Bunch.Config.parse(
                availability: [in: [:always, :on_request], default: :always],
                caps: [validate: &Caps.Matcher.validate_specs/1],
                mode: [in: [:pull, :push], default: :pull],
                demand_unit: [
                  in: [:buffers, :bytes],
                  require_if: &(&1.mode == :pull and direction == :input)
                ],
                options: [default: nil]
              ) do
      {:ok, {name, Map.put(config, :direction, direction)}}
    else
      spec: spec -> {:error, {:invalid_pad_spec, spec}}
      config: {:error, reason} -> {:error, {reason, pad: name}}
    end
  end

  @doc """
  Generates docs describing pads based on pads specification.
  """
  @spec generate_docs_from_pads_specs([{Pad.name_t(), Pad.description_t()}]) :: Macro.t()
  def generate_docs_from_pads_specs(pads_specs) do
    pads_specs
    |> Enum.sort_by(fn {_, config} -> config[:direction] end)
    |> Enum.map(&generate_docs_from_pad_specs/1)
    |> Enum.reduce(fn x, acc ->
      quote do
        """
        #{unquote(acc)}
        #{unquote(x)}
        """
      end
    end)
  end

  defp generate_docs_from_pad_specs({name, config}) do
    {pad_opts, config} = config |> Map.pop(:options)

    config_doc =
      config
      |> Enum.map(fn {k, v} ->
        {
          k |> to_string() |> String.replace("_", "&nbsp;") |> String.capitalize(),
          generate_pad_property_doc(k, v)
        }
      end)
      |> Enum.map_join("\n", fn {k, v} ->
        "#{k} | #{v}"
      end)

    options_doc =
      if pad_opts != nil do
        quote do
          """
          #{Bunch.Markdown.hard_indent("Options", 4)}

          #{unquote(OptionsSpecs.generate_opts_doc(pad_opts))}
          """
        end
      else
        quote_expr("")
      end

    quote do
      """
      ### `#{inspect(unquote(name))}`

      #{unquote(config_doc)}
      """ <> unquote(options_doc)
    end
  end

  defp generate_pad_property_doc(:caps, caps) do
    caps
    |> Bunch.listify()
    |> Enum.map(fn
      {module, params} ->
        params_doc =
          params
          |> Enum.map(fn {k, v} -> Bunch.Markdown.hard_indent("`#{k}: #{inspect(v)}`") end)
          |> Enum.join(",<br />")

        "`#{inspect(module)}`, restrictions:<br />#{params_doc}"

      module ->
        "`#{inspect(module)}`"
    end)
    ~> (
      [doc] -> doc
      docs -> docs |> Enum.join(",<br />")
    )
  end

  defp generate_pad_property_doc(_k, v) do
    "`#{inspect(v)}`"
  end
end