defmodule TailF do
  @moduledoc """
  Monitor a file for changes.

  Monitors the file and sends new contents when te file changes.

  Monitoring can be done 2 methods:

  * Filesytem events
  * Polling

  Three metods of notification are supported:

  * pid (default) - sends a {:tail_f, contents}
  * {mod, fun} - Calls the given mod.fun(contents)
  * {mod, fun, [arg1, ...]} - Calls the given mod.fun(arg1, ..., contents)
  * fun/1 - Calls the given fun.(contents)

  The notification normally contains the binary contents. However, it may
  contain {:file_event, monitor_pid, :stop}

  ## Argements

  * `path` - path of the file to monitor
  * `handler` (caller pid) - the notification method
  * `init_delay` (100 ms) - delay before reading the file for the first time
  * `poll_ms` (nil) - The polling interval in ms.  A nil disables polling
  * `monitor` (true) - When true, file system events are used
  """
  use GenServer

  require Logger

  @type t :: %__MODULE__{
    buffer: binary,
    fd: pid | nil,
    handler: pid | {atom, atom} | {atom, atom, list} | (any -> no_return) | nil,
    loc: integer,
    mode: :line | :binary,
    path: binary | nil,
    poll_ms: integer | nil,
    poll_timer_ref: reference | nil,
    watcher: pid | nil
  }

  defstruct buffer: "",
            fd: nil,
            handler: nil,
            loc: 0,
            mode: :line,
            path: nil,
            poll_ms: nil,
            poll_timer_ref: nil,
            watcher: nil

  def start_link(args) do
    GenServer.start_link(__MODULE__, Keyword.put_new(args, :handler, self()))
  end

  def status(pid) do
    GenServer.call(pid, :status)
  end

  def init(args) do
    fname = args[:path]
    monitor = Keyword.get(args, :fs_monitor, true)
    mode = args[:mode] || :binary

    Logger.info("Starting TailF for file: #{inspect fname}")
    Logger.debug(fn -> "args: " <> inspect(args) end)

    {:ok, fd} = File.open(fname, [:read, :utf8])

    Process.send_after(self(), :initialize, args[:init_delay] || 100)

    {:ok, start_fs_monitor(%__MODULE__{mode: mode, fd: fd, path: fname, poll_ms: args[:poll_ms], handler: args[:handler]}, monitor)}
  end

  def handle_info(:initialize, state) do
    Logger.debug(fn -> "initialize: " <> inspect(state) end)
    state
    |> reader()
    |> start_poll_timer()
    |> noreply()
  end

  def handle_info(:read, state) do
    state
    |> start_poll_timer()
    |> reader()
    |> noreply()
  end

  def handle_info({:file_event, watcher, {path, events}}, %{watcher: watcher} = state) do
    if debug(), do: Logger.info("file_event: " <> inspect({path, events}))
    state
    |> reader()
    |> noreply()
  end

  def handle_info({:file_event, watcher, :stop} = ev, %{watcher: watcher} = state) do
    state
    |> process_content(ev)
    |> noreply()
  end

  def handle_info(other, state) do
    Logger.warn("unknown info event: " <> inspect(other))
    noreply(state)
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  defp reader(%{fd: fd, buffer: buffer, loc: loc} = state) do
    case :file.pread(fd, loc, 1000) do
      {:ok, content} ->
        reader(%{state | buffer: buffer <> content, loc: loc + byte_size(content)})

      :eof ->
        if buffer == "" do
          state
        else
          process_content(%{state | buffer: ""}, format_content(state, buffer))
        end
    end
  end

  defp process_content(%{handler: pid} = state, content) when is_pid(pid) do
    send(pid, {:tail_f, content})
    state
  end

  defp process_content(%{handler: {mod, fun}} = state, content) do
    try do
      apply(mod, fun, [content])
    rescue
      e -> Logger.warn("exception: " <> inspect(e))
    end
    state
  end

  defp process_content(%{handler: {mod, fun, args}} = state, content) do
    try do
      apply(mod, fun, args ++ [content])
    rescue
      e -> Logger.warn("exception: " <> inspect(e))
    end
    state
  end

  defp process_content(%{handler: callback} = state, content) when is_function(callback, 1) do
    try do
      callback.(content)
    rescue
      e -> Logger.warn("exception: " <> inspect(e))
    end
    state
  end

  defp process_content(%{handler: nil} = state, content) when is_binary(content) do
    IO.puts("tail_f: " <> to_string(content))
    state
  end

  defp process_content(%{handler: nil} = state, content) do
    IO.inspect(content, label: "tail_f")
    state
  end

  defp start_poll_timer(%{poll_ms: nil} = state) do
    state
  end

  defp start_poll_timer(%{poll_ms: poll_ms} = state) do
    if ref = state.poll_timer_ref, do: Process.cancel_timer(ref)
    %{state | poll_timer_ref: Process.send_after(self(), :read, poll_ms)}
  end

  defp start_fs_monitor(state, true) do
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [state.path])
    FileSystem.subscribe(watcher_pid)
    %{state | watcher: watcher_pid}
  end

  defp start_fs_monitor(state, _) do
    state
  end

  defp noreply(%{} = state) do
    {:noreply, state}
  end

  defp format_content(%{mode: :line}, content) when is_binary(content) do
    String.split(content, "\n")
  end

  defp format_content(_, content) do
    content
  end

  defp debug, do: Application.get_env(:tail_f, :debug)
end
