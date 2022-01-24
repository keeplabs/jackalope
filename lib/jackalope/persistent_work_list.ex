defmodule Jackalope.PersistentWorkList do
  @moduledoc """
  A work list whose work items are persisted as individual files.
  """

  use GenServer

  alias Jackalope.WorkList.Expiration

  require Logger

  @default_max_size 100
  @tick_delay 10 * 60 * 1_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            # The maximum number of items that can be persisted as files
            max_size: non_neg_integer(),
            # The lowest index of an unexpired, not-pending item. No pending item has an index >= bottom_index.
            bottom_index: non_neg_integer(),
            # The index at which the next item will be pushed
            next_index: non_neg_integer(),
            # Set of indices  of expired items, between the bottom index and the next index,
            # used to get a correct count of work items.
            expired: MapSet.t(),
            # Cache of item expiration times
            expirations: %{required(non_neg_integer()) => integer},
            # Indices of execution-completion-pending items mapped by their references.
            # Indices are always taken at bottom_index.
            pending: %{required(reference()) => non_neg_integer()},
            # The file directory containing the persisted unexpired, not-completed work items
            data_dir: String.t(),
            # The function to use to get an item's expiration
            expiration_fn: fun(),
            # The function to use to update an item's expiration
            update_expiration_fn: fun()
          }

    defstruct bottom_index: 0,
              next_index: 0,
              expired: MapSet.new(),
              expirations: %{},
              pending: %{},
              data_dir: nil,
              max_size: nil,
              expiration_fn: nil,
              update_expiration_fn: nil
  end

  @doc "Create a new work list"
  @spec new(function(), function(), non_neg_integer(), Keyword.t()) :: pid()
  def new(expiration_fn, update_expiration_fn, max_size \\ @default_max_size, opts \\ []) do
    options =
      Keyword.merge(opts,
        expiration_fn: expiration_fn,
        update_expiration_fn: update_expiration_fn,
        max_size: max_size
      )

    Logger.info("[Jackalope] Starting #{__MODULE__} with #{inspect(opts)}")
    {:ok, pid} = GenServer.start_link(__MODULE__, options)
    pid
  end

  @impl GenServer
  def init(opts) do
    send(self(), :tick)

    initial_state =
      %State{
        max_size: Keyword.get(opts, :max_size),
        data_dir: Keyword.get(opts, :data_dir, "/data/jackalope"),
        expiration_fn: Keyword.fetch!(opts, :expiration_fn),
        update_expiration_fn: Keyword.fetch!(opts, :update_expiration_fn)
      }
      |> recover()

    {:ok, initial_state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    :ok = record_time_now(state)
    Process.send_after(self(), :tick, @tick_delay)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    {:reply, count(state), state}
  end

  def handle_call(:count_pending, _from, state) do
    {:reply, count_pending(state), state}
  end

  def handle_call(:peek, _from, state) do
    {:reply, peek_last(state), state}
  end

  def handle_call({:push, item}, _from, state) do
    updated_state = push_first(item, state)
    {:reply, :ok, bound_items(updated_state)}
  end

  def handle_call(:pop, _from, state) do
    updated_state = pop(state)
    {:reply, :ok, updated_state}
  end

  def handle_call({:pending, ref}, _from, state) do
    updated_state =
      %State{state | pending: Map.put(state.pending, ref, state.bottom_index)}
      |> move_bottom_index()

    {:reply, :ok, updated_state}
  end

  def handle_call({:done, ref}, _from, state) do
    case Map.get(state.pending, ref) do
      nil ->
        Logger.warn(
          "[Jackalope] Unknown pending work list item reference #{inspect(ref)}. Ignored."
        )

        {:reply, nil, state}

      index ->
        {:ok, item} = work_item_at(index, state, remove: true)

        updated_state =
          %State{state | pending: Map.delete(state.pending, ref)}
          |> cleanup_expired()

        {:reply, item, updated_state}
    end
  end

  def handle_call(:remove_all, _from, state) do
    {:ok, _} = File.rm_rf(state.data_dir)
    :ok = File.mkdir_p!(state.data_dir)

    {:reply, :ok,
     %State{
       state
       | bottom_index: 0,
         next_index: 0,
         pending: %{},
         expired: MapSet.new(),
         expirations: %{}
     }}
  end

  def handle_call(:reset_pending, _from, state) do
    bottom_index =
      case bottom_pending_index(state) do
        nil -> state.bottom_index
        index -> index
      end

    updated_state =
      %State{state | bottom_index: bottom_index, pending: %{}}
      |> cleanup_expired()

    {:reply, :ok, updated_state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    record_time_now(state)
  end

  ## PRIVATE

  defp count(state) do
    (state.next_index - state.bottom_index - Enum.count(state.expired))
    |> max(0)
  end

  defp count_pending(state), do: Enum.count(state.pending)

  # Ought to be the same as Enum.count(state.expirations)
  defp total_count(state), do: count(state) + count_pending(state)

  defp record_time_now(state) do
    time = Expiration.now() |> Integer.to_string()
    path = Path.join(state.data_dir, "time")
    :ok = File.write!(path, time, [:write])
  end

  # Peek at oldest unprocessed, unexpired work item
  defp peek_last(state) do
    cond do
      empty?(state) ->
        nil

      true ->
        # If this fails, let it crash
        {:ok, item} = work_item_at(state.bottom_index, state)
        item
    end
  end

  defp push_first(item, state) do
    index = state.next_index
    :ok = store_work_item(item, index, state)
    expiration = state.expiration_fn.(item)

    %State{
      state
      | next_index: index + 1,
        expirations: Map.put(state.expirations, index, expiration)
    }
  end

  defp pop(state) do
    index = state.bottom_index
    path = work_item_file_path(index, state)
    # If this fails, let it crash
    :ok = File.rm!(path)

    %State{state | expirations: Map.delete(state.expirations, index)}
    |> move_bottom_index()
  end

  # Move bottom index up until it is not an expired
  defp move_bottom_index(state) do
    next_bottom_index = state.bottom_index + 1

    cond do
      next_bottom_index in state.expired ->
        %State{
          state
          | bottom_index: next_bottom_index
        }
        |> move_bottom_index()

      true ->
        %State{
          state
          | bottom_index: next_bottom_index
        }
    end
  end

  defp empty?(state), do: state.bottom_index == state.next_index

  defp bottom_pending_index(state) do
    sorted_pending_indices = Map.values(state.pending) |> Enum.sort()
    if Enum.empty?(sorted_pending_indices), do: nil, else: hd(sorted_pending_indices)
  end

  # Remove from expired all indicies smaller than the smallest index of a persisted item
  defp cleanup_expired(state) do
    min_index =
      case bottom_pending_index(state) do
        nil -> state.bottom_index
        index -> min(index, state.bottom_index)
      end

    updated_expired =
      MapSet.to_list(state.expired)
      |> Enum.reject(&(&1 < min_index))
      |> MapSet.new()

    %State{state | expired: updated_expired}
  end

  defp store_work_item(item, index, state) do
    path = work_item_file_path(index, state)
    Logger.info("[Jackalope] Storing item at index #{inspect(index)} in #{inspect(path)}")
    if File.exists?(path), do: raise("Overwritting item file")
    binary = work_item_to_binary(item)
    File.write!(path, binary)
  end

  # Returns {:ok, any()} | {:error, :not_found}
  defp work_item_at(index, state, opts \\ []) do
    path = work_item_file_path(index, state)

    case File.read(path) do
      {:ok, binary} ->
        _ = if Keyword.get(opts, :remove, false), do: File.rm(path)

        work_item_from_binary(binary)

      {:error, :not_found} ->
        Logger.warn("[Jackalope] File not found #{inspect(path)}}")

        {:error, :not_found}
    end
  end

  defp work_item_file_path(index, state) do
    Path.join(state.data_dir, "#{index}.item")
  end

  defp work_item_from_binary(binary) do
    item = :erlang.binary_to_term(binary)
    {:ok, item}
  rescue
    error ->
      Logger.warn("[Jackalope] Failed to convert work item from binary: #{inspect(error)}")
      {:error, :invalid}
  end

  defp work_item_to_binary(item), do: :erlang.term_to_binary(item)

  defp bound_items(state) do
    Logger.info("BOUNDING ITEMS #{inspect(state)}")
    max = state.max_size

    if total_count(state) > max do
      updated_state = remove_expired_work_items(state)
      excess_count = total_count(updated_state) - max

      remove_excess(excess_count, updated_state)
    else
      state
    end
  end

  defp remove_expired_work_items(state) do
    if empty?(state) do
      state
    else
      Enum.reduce(
        state.bottom_index..(state.next_index - 1),
        state,
        fn index, acc ->
          maybe_expire(index, acc)
        end
      )
    end
  end

  defp maybe_expire(index, state) do
    if index in state.expired do
      state
    else
      expiration = Map.fetch!(state.expirations, index)

      if Expiration.after?(expiration, Expiration.now()) do
        state
      else
        Logger.info("[Jackalope] Expiring work item at #{index}")
        forget_item(index, state)
      end
    end
  end

  defp remove_excess(excess_count, state) when excess_count <= 0, do: state

  # Try removing excess_count work items (don't touch pending items), closest to expiration first
  defp remove_excess(excess_count, state) do
    if empty?(state) do
      state
    else
      live_indices =
        state.bottom_index..(state.next_index - 1)
        |> Enum.reject(&(&1 in state.expired))
        |> Enum.sort(fn index1, index2 ->
          Map.fetch!(state.expirations, index1) <= Map.fetch!(state.expirations, index2)
        end)
        |> Enum.take(excess_count)

      Enum.reduce(
        live_indices,
        state,
        fn index, acc -> forget_item(index, acc) end
      )
    end
  end

  defp forget_item(index, state) do
    Logger.info("[Jackalope] Forgetting work item #{index}")
    path = work_item_file_path(index, state)
    :ok = File.rm!(path)

    updated_state =
      if index == state.bottom_index do
        move_bottom_index(state)
      else
        %State{state | expired: MapSet.put(state.expired, index)}
      end

    %State{updated_state | expirations: Map.delete(state.expirations, index)} |> cleanup_expired()
  end

  defp recover(state) do
    :ok = File.mkdir_p!(state.data_dir)
    now = Expiration.now()
    # TODO - recover all *.item files as work items
    File.ls!(state.data_dir)
    |> Enum.filter(&Regex.match?(~r/.*\.item/, &1))
    |> Enum.reduce(state, &recover_file(Path.join(state.data_dir, &1), now, &2))
    |> reset_indices_after_recovery()
  end

  defp recover_file(file, now, state) do
    %{"index" => index_s} = Regex.named_captures(~r/(?<index>\d+)\.item/, file)
    {index, _} = Integer.parse(index_s)
    binary = File.read!(file)
    :ok = File.rm!(file)

    updated_state =
      case work_item_from_binary(binary) do
        {:ok, item} ->
          # TODO - do some validation, version checking...
          rebased_expiration =
            Expiration.rebase_expiration(state.expiration_fn.(item), latest_time(state), now)

          rebased_item = state.update_expiration_fn.(item, rebased_expiration)
          :ok = store_work_item(rebased_item, index, state)
          %State{state | expirations: Map.put(state.expirations, index, rebased_expiration)}

        {:error, :invalid} ->
          state
      end

    updated_state
  end

  defp reset_indices_after_recovery(state) do
    indices = Map.keys(state.expirations)

    if Enum.empty?(indices) do
      state
    else
      bottom_index = Enum.min(indices)
      next_index = Enum.max(indices) + 1
      expired = Enum.filter(bottom_index..next_index, &(&1 not in indices))

      %State{
        state
        | bottom_index: bottom_index,
          next_index: next_index,
          expired: MapSet.new(expired)
      }
    end
  end

  defp latest_time(state) do
    path = Path.join(state.data_dir, "time")

    if File.exists?(path) do
      time_s = File.read!(path)
      {time, _} = Integer.parse(time_s)
      time
    else
      Logger.info("[Jackalope] No latest time found for recovery. Using now.")
      Expiration.now()
    end
  end
end

defimpl Jackalope.WorkList, for: PID do
  @impl Jackalope.WorkList
  def peek(work_list) do
    GenServer.call(work_list, :peek)
  end

  @impl Jackalope.WorkList
  def push(work_list, item) do
    :ok = GenServer.call(work_list, {:push, item})
    work_list
  end

  @impl Jackalope.WorkList
  def pop(work_list) do
    :ok = GenServer.call(work_list, :pop)
    work_list
  end

  @impl Jackalope.WorkList
  def pending(work_list, ref) do
    :ok = GenServer.call(work_list, {:pending, ref})
    work_list
  end

  @impl Jackalope.WorkList
  def reset_pending(work_list) do
    :ok = GenServer.call(work_list, :reset_pending)
    work_list
  end

  @impl Jackalope.WorkList
  def done(work_list, ref) do
    item = GenServer.call(work_list, {:done, ref})
    {work_list, item}
  end

  @impl Jackalope.WorkList
  def count(work_list) do
    GenServer.call(work_list, :count)
  end

  @impl Jackalope.WorkList
  def count_pending(work_list) do
    GenServer.call(work_list, :count_pending)
  end

  @impl Jackalope.WorkList
  def empty?(work_list), do: peek(work_list) == nil

  @impl Jackalope.WorkList
  def remove_all(work_list) do
    :ok = GenServer.call(work_list, :remove_all)
    work_list
  end
end
