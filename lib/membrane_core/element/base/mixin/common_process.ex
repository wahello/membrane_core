defmodule Membrane.Element.Base.Mixin.CommonProcess do
  @moduledoc """
  This module is a mixin with common routines for all elements regarding
  their process lifecycle.
  """


  defmacro __using__(_) do
    quote location: :keep do
      use GenServer


      # Callbacks

      @doc false
      @spec init(struct) :: {:ok, map} | {:error, any}
      def init(options) do
        # Call element initialization callback
        case __MODULE__.handle_init(options) do
          {:ok, element_state} ->
            debug("Initialized: element_state = #{inspect(element_state)}")

            # Store module name in the process dictionary so it can be used
            # to retreive module from PID in `Membrane.Element.get_module/1`.
            Process.put(:membrane_element_module, __MODULE__)

            # Return initial state of the server, including element state.
            {:ok, %{
              playback_state: :stopped,
              link_destinations: [],
              element_state: element_state
            }}

          {:error, reason} ->
            warn("Failed to initialize: reason = #{inspect(reason)}")
            {:stop, reason}
        end
      end


      # TODO implement terminate callback and handle_shutdown element callback
    end
  end
end
