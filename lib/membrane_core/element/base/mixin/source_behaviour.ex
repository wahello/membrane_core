defmodule Membrane.Element.Base.Mixin.SourceBehaviour do
  @moduledoc false


  @doc """
  Callback that defines what source pads may be ever available for this
  element type.

  It should return a map where:

  * key contains pad name. That may be either atom (like `:source`,
    `:something_else` for pads that are always available, or string for pads
    that are added dynamically),
  * value is a tuple where:
    * first item of the tuple contains pad availability. It may be set only
      `:always` at the moment,
    * second item of the tuple contains pad mode (`:pull` or `:push`),
    * third item of the tuple contains `:any` or list of caps that can be
      knownly generated from this pad.

  The default name for generic source pad, in elements that just produce some
  buffers is `:source`.
  """
  @callback known_source_pads() :: Membrane.Pad.known_pads_t


  @doc """
  Macro that defines known source pads for the element type.

  It automatically generates documentation from the given definition.
  """
  defmacro def_known_source_pads(source_pads) do
    quote do
      module_name = String.slice(to_string(__MODULE__),
        String.length("Elixir."), String.length(to_string(__MODULE__)))

      docstring =
        "Returns all known source pads for `#{module_name}`.\n\n" <>
        "They are the following:\n\n" <>
        Membrane.Helper.Doc.generate_known_pads_docs(unquote(source_pads))

      Module.add_doc(__MODULE__, __ENV__.line + 1, :def, {:known_source_pads, 0}, [], docstring)
      @spec known_source_pads() :: Membrane.Pad.known_pads_t
      def known_source_pads(), do: unquote(source_pads)
    end
  end


  @doc """
  Callback that is called when buffer should be produced by the source.

  It will be called only for pads in the pull mode, as in their case demand
  is triggered by the sinks.

  For pads in the push mode, Element.Manager should generate buffers without this
  callback. Example scenario might be reading a stream over TCP, waiting
  for incoming packets that will be delivered to the PID of the element,
  which will result in calling `handle_other/2`, which can return value that
  contains the `:buffer` action.

  It is safe to use blocking reads in the filter. It will cause limiting
  throughput of the pipeline to the capability of the source.

  The arguments are:

  * name of the pad receiving a demand request,
  * requested number of units
  * unit
  * params
  * current element's state.
  """
  @callback handle_demand(any, non_neg_integer, Membrane.Buffer.Metric.unit_t, any, any) ::
    Membrane.Element.Base.Mixin.CommonBehaviour.callback_return_t


  defmacro __using__(_) do
    quote location: :keep do
      @behaviour Membrane.Element.Base.Mixin.SourceBehaviour

      import Membrane.Element.Base.Mixin.SourceBehaviour, only: [def_known_source_pads: 1]
    end
  end
end
