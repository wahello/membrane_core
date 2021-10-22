defmodule Membrane.Core.Parent.MessageDispatcher do
  @moduledoc false

  import Membrane.Helper.GenServer

  alias Membrane.Core.{Parent, Pipeline, TimerController}
  alias Membrane.Core.Message
  alias Membrane.Core.Parent.{ChildLifeController, LifecycleController}

  require Membrane.Core.Message
  require Membrane.Logger

  @spec handle_message(Message.t(), Parent.state_t()) ::
          Membrane.Helper.GenServer.genserver_return_t()
          | {:stop, reason :: :normal, Parent.state_t()}
  def handle_message(
        Message.new(:playback_state_changed, [pid, new_playback_state]),
        state
      ) do
    ChildLifeController.child_playback_changed(pid, new_playback_state, state)
    |> noreply(state)
  end

  def handle_message(Message.new(:change_playback_state, new_state), state) do
    LifecycleController.change_playback_state(new_state, state)
    |> noreply(state)
  end

  def handle_message(Message.new(:notification, [from, notification]), state) do
    LifecycleController.handle_notification(from, notification, state)
    |> noreply(state)
  end

  def handle_message(Message.new(cb, [element_name, pad_ref]), state)
      when cb in [:handle_start_of_stream, :handle_end_of_stream] do
    inform_parent(state, cb, [pad_ref])

    LifecycleController.handle_stream_management_event(cb, element_name, pad_ref, state)
    |> noreply(state)
  end

  def handle_message(Message.new(:log_metadata, metadata), state) do
    LifecycleController.handle_log_metadata(metadata, state)
    |> noreply(state)
  end

  def handle_message(Message.new(:timer_tick, timer_id), state) do
    TimerController.handle_tick(timer_id, state) |> noreply(state)
  end

  def handle_message(Message.new(:link_response, link_id), state) do
    Membrane.Logger.debug("link response #{inspect(link_id)}")

    {spec_ref, state} =
      get_and_update_in(state, [:pending_links, link_id], fn pending_link ->
        %{to_respond: to_respond, spec_ref: spec_ref} = pending_link
        {spec_ref, %{pending_link | to_respond: to_respond - 1}}
      end)

    pending_links =
      state.pending_links
      |> Map.values()
      |> Enum.filter(&(&1.spec_ref == spec_ref))

    Membrane.Logger.debug("pending links: #{inspect(pending_links)}")

    if Enum.all?(pending_links, &(&1.to_respond == 0)) do
      {bin_links, non_bin_links} =
        pending_links
        |> Enum.map(& &1.link)
        |> Enum.split_with(&({Membrane.Bin, :itself} in [&1.from.child, &1.to.child]))

      {:ok, state} = ChildLifeController.LinkHandler.link_children(non_bin_links, state)

      state =
        if bin_links == [] do
          ChildLifeController.StartupHandler.init_playback_state(spec_ref, state)
        else
          bin_links
          |> Enum.flat_map(&[&1.from, &1.to])
          |> Enum.filter(&(&1.child == {Membrane.Bin, :itself}))
          |> Enum.reduce(state, fn endpoint, state ->
            link_id = Membrane.Core.Child.PadModel.get_data!(state, endpoint.pad_ref, :link_id)

            if link_id do
              Membrane.Logger.debug("Sending link response")
              Message.send(state.watcher, :link_response, link_id)
              state
            else
              Membrane.Core.Child.PadModel.set_data!(
                state,
                endpoint.pad_ref,
                :response_received?,
                true
              )
            end
          end)
        end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_message({:membrane_clock_ratio, clock, ratio}, state) do
    TimerController.handle_clock_update(clock, ratio, state) |> noreply(state)
  end

  def handle_message({:DOWN, _ref, :process, pid, reason} = message, state) do
    cond do
      is_child_pid?(pid, state) -> ChildLifeController.handle_child_death(pid, reason, state)
      is_parent_pid?(pid, state) -> {:stop, {:shutdown, :parent_crash}, state}
      true -> LifecycleController.handle_other(message, state)
    end
    |> noreply(state)
  end

  def handle_message(message, state) do
    LifecycleController.handle_other(message, state)
    |> noreply(state)
  end

  defp inform_parent(state, msg, msg_params) do
    if not pipeline?(state) and state.parent_pid,
      do: Message.send(state.parent_pid, msg, [state.name | msg_params])
  end

  defp is_parent_pid?(pid, state) do
    state.parent_pid == pid
  end

  defp is_child_pid?(pid, state) do
    Enum.any?(state.children, fn {_name, entry} -> entry.pid == pid end)
  end

  defp pipeline?(%Pipeline.State{}), do: true
  defp pipeline?(_state), do: false
end
