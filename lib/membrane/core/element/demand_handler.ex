defmodule Membrane.Core.Element.DemandHandler do
  @moduledoc false

  # Module handling demands requested on output pads.

  use Bunch

  alias Membrane.Buffer
  alias Membrane.Core.InputBuffer
  alias Membrane.Core.Child.PadModel

  alias Membrane.Core.Element.{
    BufferController,
    CapsController,
    DemandController,
    EventController,
    State
  }

  alias Membrane.Pad

  require Membrane.Core.Child.PadModel
  require Membrane.Core.Message
  require Membrane.Logger

  @doc """
  Called when redemand action was returned.
    * If element is currently supplying demand it means that after finishing supply_demand it will call
      `handle_delayed_demands`.
    * If element isn't supplying demand at the moment `handle_demand` is invoked right away, and it will
      invoke handle_demand callback, which will probably return :redemand and :buffers actions and in
      that way source will synchronously supply demand.
  """
  @spec handle_redemand(Pad.ref_t(), State.t()) :: {:ok, State.t()}
  def handle_redemand(pad_ref, %State{supplying_demand?: true} = state) do
    state =
      state
      |> Map.update!(:delayed_demands, &MapSet.put(&1, {pad_ref, :redemand}))

    {:ok, state}
  end

  def handle_redemand(pad_ref, state) do
    DemandController.handle_demand(pad_ref, 0, state)
  end

  @doc """
  If element is not supplying demand currently, this function supplies
  demand right away by taking buffers from the InputBuffer of the given pad
  and passing it to proper controllers.

  If element is currently supplying demand it delays supplying demand until all
  current processing is finished.

  This is necessary due to the case when one requests a demand action while previous
  demand is being supplied. This could lead to a situation where buffers are taken
  from InputBuffer and passed to callbacks, while buffers being currently supplied
  have not been processed yet, and therefore to changing order of buffers.
  """
  @spec supply_demand(
          Pad.ref_t(),
          State.t()
        ) :: {:ok, State.t()} | {{:error, any()}, State.t()}
  def supply_demand(pad_ref, size, state) do
    state = update_demand(pad_ref, size, state)
    supply_demand(pad_ref, state)
  end

  def supply_demand(pad_ref, %State{supplying_demand?: true} = state) do
    state =
      state
      |> Map.update!(:delayed_demands, &MapSet.put(&1, {pad_ref, :supply}))

    {:ok, state}
  end

  def supply_demand(pad_ref, state) do
    with {:ok, state} <- do_supply_demand(pad_ref, state) do
      handle_delayed_demands(state)
    end
  end

  defp do_supply_demand(pad_ref, state) do
    # marking is state that actual demand supply has been started (note changing back to false when finished)
    state = %State{state | supplying_demand?: true}

    pad_data = state |> PadModel.get_data!(pad_ref)

    {{_buffer_status, data}, new_input_buf} =
      InputBuffer.take_and_demand(
        pad_data.input_buf,
        pad_data.demand,
        pad_data.pid,
        pad_data.other_ref
      )

    state = PadModel.set_data!(state, pad_ref, :input_buf, new_input_buf)

    with {:ok, state} <- handle_input_buf_output(pad_ref, data, state) do
      {:ok, %State{state | supplying_demand?: false}}
    else
      {{:error, reason}, state} ->
        Membrane.Logger.error("""
        Error while supplying demand on pad #{inspect(pad_ref)} of size #{inspect(pad_data.demand)}
        """)

        {{:error, {:supply_demand, reason}}, %State{state | supplying_demand?: false}}
    end
  end

  @spec handle_outgoing_buffers(
          Pad.ref_t(),
          Membrane.Pad.Data.t(),
          [Buffer.t()],
          State.t()
        ) :: State.t()
  def handle_outgoing_buffers(
        pad_ref,
        %{mode: :pull, other_demand_unit: other_demand_unit},
        buffers,
        state
      ) do
    buf_size = Buffer.Metric.from_unit(other_demand_unit).buffers_size(buffers)
    PadModel.update_data!(state, pad_ref, :demand, &(&1 - buf_size))
  end

  def handle_outgoing_buffers(_pad_ref, %{mode: :push, toilet: toilet} = data, buffers, state)
      when is_reference(toilet) do
    %{other_demand_unit: other_demand_unit, pid: pid} = data
    buf_size = Buffer.Metric.from_unit(other_demand_unit).buffers_size(buffers)
    toilet_size = :atomics.add_get(toilet, 1, buf_size)

    if toilet_size > 200 do
      Membrane.Logger.debug_verbose(~S"""
      Toilet overflow

                   ` ' `
               .'''. ' .'''.
                 .. ' ' ..
                '  '.'.'  '
                .'''.'.'''.
               ' .''.'.''. '
             ;------ ' ------;
             | ~~ .--'--//   |
             |   /   '   \   |
             |  /    '    \  |
             |  |    '    |  |  ,----.
             |   \ , ' , /   | =|____|=
             '---,###'###,---'  (---(
                /##  '  ##\      )---)
                |##, ' ,##|     (---(
                 \'#####'/       `---`
                  \`"#"`/
                   |`"`|
                 .-|   |-.
            jgs /  '   '  \
                '---------'
      """)

      Membrane.Logger.error("""
      Toilet overflow.

      Reached the size of #{inspect(toilet_size)},
      which is above fail level when storing data from output working in push mode.
      To have control over amount of buffers being produced, consider using pull mode.
      """)

      Process.exit(pid, :kill)
    end

    state
  end

  def handle_outgoing_buffers(_pad_ref, _pad_data, _buffers, state) do
    state
  end

  defp update_demand(pad_ref, size, state) when is_integer(size) do
    PadModel.set_data!(state, pad_ref, :demand, size)
  end

  defp update_demand(pad_ref, size_fun, state) when is_function(size_fun) do
    PadModel.update_data!(
      state,
      pad_ref,
      :demand,
      fn demand ->
        new_demand = size_fun.(demand)

        if new_demand < 0 do
          raise Membrane.ElementError,
                "Demand altering function requested negative demand on pad #{inspect(pad_ref)} in #{state.module}"
        end

        new_demand
      end
    )
  end

  @spec handle_delayed_demands(State.t()) :: State.stateful_try_t()
  defp handle_delayed_demands(%State{delayed_demands: del_dem} = state)
       when del_dem == %MapSet{} do
    {:ok, state}
  end

  defp handle_delayed_demands(%State{delayed_demands: del_dem} = state) do
    # Taking random element of `:delayed_demands` is done to keep data flow
    # balanced among pads, i.e. to prevent situation where demands requested by
    # one pad are supplied right away while another one is waiting for buffers
    # potentially for a long time.
    [{pad_ref, action}] = del_dem |> Enum.take_random(1)
    state = %State{state | delayed_demands: del_dem |> MapSet.delete({pad_ref, action})}

    res =
      case action do
        :supply -> do_supply_demand(pad_ref, state)
        :redemand -> handle_redemand(pad_ref, state)
      end

    with {:ok, state} <- res do
      handle_delayed_demands(state)
    end
  end

  @spec handle_input_buf_output(
          Pad.ref_t(),
          [InputBuffer.output_value_t()],
          State.t()
        ) :: State.stateful_try_t()
  defp handle_input_buf_output(pad_ref, data, state) do
    data
    |> Bunch.Enum.try_reduce(state, fn v, state ->
      do_handle_input_buf_output(pad_ref, v, state)
    end)
  end

  @spec do_handle_input_buf_output(
          Pad.ref_t(),
          InputBuffer.output_value_t(),
          State.t()
        ) :: State.stateful_try_t()
  defp do_handle_input_buf_output(pad_ref, {:event, e}, state),
    do: EventController.exec_handle_event(pad_ref, e, state)

  defp do_handle_input_buf_output(pad_ref, {:caps, c}, state),
    do: CapsController.exec_handle_caps(pad_ref, c, state)

  defp do_handle_input_buf_output(
         pad_ref,
         {:buffers, buffers, size},
         state
       ) do
    state = PadModel.update_data!(state, pad_ref, :demand, &(&1 - size))

    if toilet = PadModel.get_data!(state, pad_ref, :toilet) do
      :atomics.sub(toilet, 1, size)
    end

    BufferController.exec_buffer_handler(pad_ref, buffers, state)
  end
end
