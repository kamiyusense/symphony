defmodule SymphonyElixir.LocalProcess do
  @moduledoc """
  Owns a local command's PID namespace until every descendant has exited.
  A per-workspace OS lock and identity record survive an abrupt VM exit.
  This Linux-only boundary never schedules or retries model work.
  """

  @external_resource Path.expand("../../priv/local_process.py", __DIR__)
  @helper_source File.read!(@external_resource)

  @spec open(Path.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def open(workspace, command, opts \\ []) do
    case System.find_executable("python3") do
      nil ->
        {:error, :local_process_python_missing}

      python ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(python)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: Enum.map(["-B", "-c", @helper_source, "run", workspace, command], &String.to_charlist/1),
              cd: String.to_charlist(workspace)
            ] ++ opts
          )

        {:ok, port}
    end
  end

  @spec recover(Path.t()) :: :ok | {:error, term()}
  def recover(workspace), do: control("recover", workspace)

  @spec drain(Path.t()) :: :ok | {:error, term()}
  def drain(workspace), do: await_stopped(workspace, System.monotonic_time(:millisecond) + 4_000)

  @spec snapshot(Path.t()) :: :ok | {:error, term()}
  def snapshot(workspace), do: control("snapshot", workspace)

  @spec stop(port(), Path.t()) :: :ok | {:error, term()}
  def stop(port, workspace) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    await_stopped(workspace, System.monotonic_time(:millisecond) + 4_000)
  end

  @spec run(String.t(), Path.t(), pos_integer()) :: {:ok, {String.t(), integer()}} | {:error, term()}
  def run(command, workspace, timeout_ms) do
    with {:ok, port} <- open(workspace, command) do
      collect(port, workspace, [], System.monotonic_time(:millisecond) + timeout_ms)
    end
  end

  defp collect(port, workspace, chunks, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, bytes}} ->
        collect(port, workspace, [bytes | chunks], deadline)

      {^port, {:exit_status, status}} ->
        with :ok <- recover(workspace), do: {:ok, {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}}
    after
      remaining ->
        with :ok <- stop(port, workspace), do: {:error, :timeout}
    end
  end

  defp await_stopped(workspace, deadline) do
    case recover(workspace) do
      :ok ->
        :ok

      error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await_stopped(workspace, deadline)
        else
          error
        end
    end
  end

  defp control(mode, workspace) do
    case System.find_executable("python3") do
      nil ->
        {:error, :local_process_python_missing}

      python ->
        case System.cmd(python, ["-B", "-c", @helper_source, mode, workspace], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, status} -> {:error, {:local_process_no_go, status, output}}
        end
    end
  end
end
