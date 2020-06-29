defmodule TailFTest do
  use ExUnit.Case

  alias TailFTest.Test

  doctest TailF

  @path "/tmp/tail_f"

  setup_all do
    {:ok, test} = Test.start()
    {:ok, test: test}
  end

  setup meta do
    content = test_content()
    :ok = File.write(@path, content)

    if Map.get(meta, :start, true) do
      {:ok, pid} = TailF.start_link(path: @path, init_delay: 1)
      {:ok, pid: pid, content: content}
    else
      {:ok, content: content}
    end
  end

  test "content on startup", %{pid: _pid, content: content} do
    assert_receive {:tail_f, ^content}
  end

  test "watcher", %{pid: pid, content: content} do
    assert_receive {:tail_f, ^content}
    assert TailF.status(pid).watcher
    assert TailF.status(pid).handler |> is_pid()
    refute TailF.status(pid).poll_ms
    line = "\nanother line"
    :ok = File.write(@path, line, [:append])
    assert_receive {:tail_f, ^line}, 1000
  end

  @tag start: false
  test "poller", %{content: content} do
    {:ok, pid} = TailF.start_link(path: @path, init_delay: 1, poll_ms: 10, fs_monitor: false)
    assert_receive {:tail_f, ^content}
    refute TailF.status(pid).watcher
    assert TailF.status(pid).poll_timer_ref
    line = "\nanother line"
    :ok = File.write(@path, line, [:append])
    assert_receive {:tail_f, ^line}, 20
  end

  @tag start: false
  test "mf notification", %{content: content} do
    Test.set_pid(self())

    {:ok, pid} = TailF.start_link(path: @path, init_delay: 1, poll_ms: 5, fs_monitor: false, handler: {Test, :callback})
    assert_receive {:content, ^content}
    refute TailF.status(pid).watcher
    assert TailF.status(pid).poll_timer_ref
    line = "\nanother line"
    :ok = File.write(@path, line, [:append])
    assert_receive {:content, ^line}, 500
  end

  @tag start: false
  test "mfa notification", %{content: content} do
    Test.set_pid(self())

    {:ok, pid} = TailF.start_link(path: @path, init_delay: 1, poll_ms: 5, fs_monitor: false, handler: {Test, :callback, [:test]})
    assert_receive {:content2, :test, ^content}
    refute TailF.status(pid).watcher
    assert TailF.status(pid).poll_timer_ref
    line = "\nanother line"
    :ok = File.write(@path, line, [:append])
    assert_receive {:content2, :test, ^line}, 500
  end

  @tag start: false
  test "fun notification", %{content: content} do
    self = self()
    callback = &send(self, {:content3, &1})
    {:ok, pid} = TailF.start_link(path: @path, init_delay: 1, poll_ms: 5, fs_monitor: false, handler: callback)
    assert_receive {:content3, ^content}
    refute TailF.status(pid).watcher
    assert TailF.status(pid).poll_timer_ref
    line = "\nanother line"
    :ok = File.write(@path, line, [:append])
    assert_receive {:content3, ^line}, 500
    Process.sleep(100)
  end

  test "monitor stop", %{pid: pid, content: content} do
    assert_receive {:tail_f, ^content}
    watcher = TailF.status(pid).watcher
    assert is_pid(watcher)
    event = {:file_event, watcher, :stop}
    send(pid, event)
    assert_receive {:tail_f, ^event}, 1000
  end

  defmodule Test do
    use GenServer
    def start(pid \\ nil), do: GenServer.start(__MODULE__, pid, name: __MODULE__)
    def set_pid(pid), do: GenServer.cast(__MODULE__, {:set_pid, pid})
    def callback(content), do: GenServer.cast(__MODULE__, {:content, content})
    def callback(arg, content), do: GenServer.cast(__MODULE__, {:content, arg, content})

    def init(pid), do: {:ok, pid}
    def handle_cast({:content, content}, pid) do
      send(pid, {:content, content})
      {:noreply, pid}
    end
    def handle_cast({:content, arg, content}, pid) do
      send(pid, {:content2, arg, content})
      {:noreply, pid}
    end
    def handle_cast({:set_pid, pid}, _), do: {:noreply, pid}
  end

  defp test_content, do: """
    line 1
    line 2
    """
end
