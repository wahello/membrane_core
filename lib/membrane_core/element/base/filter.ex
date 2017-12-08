defmodule Membrane.Element.Base.Filter do

  @doc """
  Callback that is called when buffer arrives.

  The arguments are:
    - name of the pad receiving a buffer,
    - current caps of this pad,
    - buffer,
    - current element state.
  """
  @callback handle_process(any, list(Membrane.Buffer.t), any, any) ::
    Membrane.Element.Base.Mixin.CommonBehaviour.callback_return_t


  defmacro __using__(_) do
    quote location: :keep do
      use Membrane.Element.Base.Mixin.CommonBehaviour
      use Membrane.Element.Base.Mixin.SourceBehaviour
      use Membrane.Element.Base.Mixin.SinkBehaviour
      @behaviour Membrane.Element.Base.Filter


      @doc """
      Returns module that manages this element.
      """
      @spec manager_module() :: module
      def manager_module, do: Membrane.Element.Manager.Filter


      # Default implementations

      @doc false
      def handle_caps(_pad, _caps, _params, state), do: {{:ok, forward: :all}, state}

      @doc false
      def handle_event(_pad, _event, _params, state), do: {{:ok, forward: :all}, state}

      @doc false
      def handle_demand(_pad, _size, _unit, _params, state), do:
        {{:error, :handle_demand_not_implemented}, state}

      @doc false
      def handle_process1(_pad, _buffer, _params, state), do: {:ok, state}

      @doc false
      def handle_process(pad, buffers, params, state) do
        buffers |> Membrane.Element.Manager.Common.reduce_something1_results(state, fn b, st ->
            handle_process1 pad, b, params, st
          end)
      end


      defoverridable [
        handle_caps: 4,
        handle_event: 4,
        handle_demand: 5,
        handle_process: 4,
        handle_process1: 4,
      ]
    end
  end
end
