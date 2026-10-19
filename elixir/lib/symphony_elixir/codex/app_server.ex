defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH, Workflow}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @interrupt_limit_ms 2_000
  @active_turn_key {__MODULE__, :active_turn}
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    dynamic_tool_binding = DynamicTool.bind()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, dynamic_tool_binding) do
      metadata = Map.merge(port_metadata(port, worker_host), %{session_owner: self(), app_server_session: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)})

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <-
             do_start_session(port, expanded_workspace, session_policies, dynamic_tool_binding) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           dynamic_tool_binding: dynamic_tool_binding
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{workspace: workspace, thread_id: thread_id, worker_host: worker_host, metadata: metadata} = app_session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, app_session.dynamic_tool_binding, issue: issue)
      end)

    with :ok <- validate_session_owner(app_session),
         {:ok, receipt} <- begin_turn_receipt(workspace, thread_id, issue.id, worker_host, metadata.app_server_session) do
      Process.put(@active_turn_key, %{port: app_session.port, thread_id: thread_id, turn_id: nil, issue_id: issue.id, receipt: receipt})

      try do
        result = run_active_turn(app_session, prompt, issue, on_message, tool_executor)
        # An early error/input-required/timeout can leave a live cloud turn. Interrupt before closing stdin.
        active = Process.get(@active_turn_key)

        if needs_interrupt?(active, result, workspace, worker_host) do
          interrupt_active_turn(active, [], on_message, "")
        end

        result
      after
        Process.delete(@active_turn_key)
      end
    end
  end

  defp validate_session_owner(%{port: port, metadata: %{session_owner: owner}}) when owner == self() do
    if Port.info(port, :connected) == {:connected, owner}, do: :ok, else: {:error, :session_owner_mismatch}
  end

  defp validate_session_owner(_session), do: {:error, :session_owner_mismatch}

  defp needs_interrupt?(active, result, workspace, worker_host) do
    recovery_ready(workspace, worker_host) != :ok and is_binary(active.turn_id) and
      not match?({:error, {:turn_interrupt, _}}, result)
  end

  defp run_active_turn(
         %{
           port: port,
           metadata: metadata,
           approval_policy: approval_policy,
           auto_approve_requests: auto_approve_requests,
           turn_sandbox_policy: turn_sandbox_policy,
           thread_id: thread_id,
           workspace: workspace
         },
         prompt,
         issue,
         on_message,
         tool_executor
       ) do
    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        Process.put(@active_turn_key, Map.put(Process.get(@active_turn_key), :turn_id, turn_id))
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(%{port: port, workspace: workspace, worker_host: nil}) when is_port(port) do
    SymphonyElixir.LocalProcess.stop(port, workspace)
  end

  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  @doc "Ask the session owner to interrupt its current Issue; never read another process's Port."
  @spec interrupt(pid() | nil, String.t()) :: map()
  def interrupt(owner, issue_id) when is_pid(owner) do
    ref = Process.monitor(owner)
    send(owner, {:interrupt_turn, self(), ref, issue_id})

    result =
      receive do
        {:interrupt_result, ^ref, result} -> result
        {:DOWN, ^ref, :process, ^owner, _} -> %{status: :interrupt_unconfirmed, reason: :owner_down}
      after
        interrupt_timeout() + 250 -> %{status: :interrupt_unconfirmed, reason: :owner_unresponsive}
      end

    Process.demonitor(ref, [:flush])
    result
  end

  def interrupt(_owner, _issue_id), do: %{status: :interrupt_unconfirmed, reason: :owner_missing}

  # These receipts live beside, not inside, the worker workspace and survive VM death/removal.
  # The existing LocalProcess lease serializes writers for a workspace. No scheduler/retry lives here.
  @spec recovery_ready(Path.t(), String.t() | nil) :: :ok | {:error, term()}
  def recovery_ready(workspace, worker_host \\ nil) do
    dir = turn_receipt_dir(workspace, worker_host)

    case File.lstat(dir) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        check_turn_receipts(dir, workspace)

      _ ->
        {:error, :interrupt_receipt_unreadable}
    end
  end

  defp check_turn_receipts(dir, workspace) do
    with :ok <- private_receipt_dir(dir), {:ok, names} <- File.ls(dir) do
      Enum.reduce_while(names, :ok, &check_next_receipt(&1, &2, dir, workspace))
    end
  end

  defp check_next_receipt(name, :ok, dir, workspace) do
    case check_turn_receipt(dir, name, workspace) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp check_turn_receipt(dir, name, workspace) do
    if String.ends_with?(name, ".pending") do
      pending = Path.join(dir, name)

      with {:ok, data} <- read_receipt(pending),
           {:ok, ^data} <- read_receipt(pending <> ".resolved"),
           {:ok, record} <- Jason.decode(data),
           true <- valid_turn_receipt?(record, name, workspace) do
        :ok
      else
        _ -> {:error, :interrupt_completion_unconfirmed}
      end
    else
      :ok
    end
  end

  defp valid_turn_receipt?(%{"workspace" => stored, "session" => session, "thread_id" => thread, "issue_id" => issue}, name, workspace)
       when is_binary(session) and is_binary(thread) and is_binary(issue) do
    stored == Path.expand(workspace) and session <> ".pending" == name
  end

  defp valid_turn_receipt?(_record, _name, _workspace), do: false

  defp interrupt_timeout, do: min(max(Config.settings!().codex.read_timeout_ms, 1), @interrupt_limit_ms)

  defp turn_receipt_dir(workspace, worker_host) do
    key = :crypto.hash(:sha256, Path.expand(workspace)) |> Base.encode16(case: :lower)
    base = if is_nil(worker_host), do: Path.dirname(Path.expand(workspace)), else: Path.dirname(Workflow.workflow_file_path())
    Path.join([base, ".symphony-processes", key, "turns"])
  end

  defp private_receipt_dir(dir) do
    # lstat rejects symlinks. Never chmod a pre-existing directory or follow a redirected receipt.
    with {:ok, %{type: :directory, uid: uid, mode: mode}} <- File.lstat(dir),
         {:ok, %{uid: ^uid}} <- File.stat("/proc/self"),
         true <- Bitwise.band(mode, 0o077) == 0 do
      :ok
    else
      _ -> {:error, :unsafe_interrupt_receipt_directory}
    end
  end

  defp create_receipt_dir(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
    |> case do
      :ok -> private_receipt_dir(dir)
      error -> error
    end
  end

  defp read_receipt(path) do
    with {:ok, %{type: :regular, size: size, links: 1}} <- File.lstat(path),
         true <- size <= 16_384,
         {:ok, data} <- File.read(path) do
      {:ok, data}
    else
      _ -> {:error, :invalid_interrupt_receipt}
    end
  end

  defp write_receipt(path, data) do
    case File.open(path, [:write, :binary, :exclusive, :sync]) do
      {:ok, io} ->
        try do
          IO.binwrite(io, data)
        after
          File.close(io)
        end

      error ->
        error
    end
  end

  defp begin_turn_receipt(workspace, thread_id, issue_id, worker_host, app_server_session) do
    dir = turn_receipt_dir(workspace, worker_host)

    with :ok <- recovery_ready(workspace, worker_host),
         :ok <- create_receipt_dir(Path.dirname(Path.dirname(dir))),
         :ok <- create_receipt_dir(Path.dirname(dir)),
         :ok <- create_receipt_dir(dir) do
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      path = Path.join(dir, nonce <> ".pending")
      data = Jason.encode!(%{workspace: Path.expand(workspace), thread_id: thread_id, issue_id: issue_id, session: nonce, app_server_session: app_server_session})
      with :ok <- write_receipt(path, data), do: {:ok, %{path: path, data: data, session: app_server_session}}
    end
  end

  defp resolve_turn_receipt(%{path: path, data: data}), do: write_receipt(path <> ".resolved", data)

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with :ok <- recovery_ready(expanded_workspace),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}

      {:error, _} = error ->
        error
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding) do
    SymphonyElixir.LocalProcess.open(workspace, local_launch_command(dynamic_tool_binding), env: tracker_secret_port_env(dynamic_tool_binding), line: @port_line_bytes)
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command(dynamic_tool_binding) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies, dynamic_tool_binding)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} when is_binary(thread_id) and thread_id != "" -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} when is_binary(turn_id) and turn_id != "" -> {:ok, turn_id}
      {:ok, _} -> {:error, :invalid_turn_payload}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {:interrupt_turn, caller, ref, issue_id} ->
        case Process.get(@active_turn_key) do
          %{issue_id: ^issue_id, turn_id: turn_id} = active when is_binary(turn_id) ->
            interrupt_active_turn(active, [{caller, ref}], on_message, pending_line)

          _ ->
            send(caller, {:interrupt_result, ref, %{status: :interrupt_unconfirmed, reason: :active_turn_unknown}})
            receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests)
        end

      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp interrupt_active_turn(active, callers, on_message, pending_line) do
    request_id = "interrupt-" <> Integer.to_string(System.unique_integer([:positive]))

    state = %{
      active: active,
      callers: callers,
      request_id: request_id,
      sent: false,
      response: false,
      terminal: false,
      deadline: System.monotonic_time(:millisecond) + interrupt_timeout(),
      on_message: on_message
    }

    result =
      try do
        line = Jason.encode!(%{"id" => request_id, "method" => "turn/interrupt", "params" => %{"threadId" => active.thread_id, "turnId" => active.turn_id}}) <> "\n"
        # Do not suspend on a full stdio Port and thereby bypass the bounded deadline.
        case Port.command(active.port, line, [:nosuspend]) do
          true -> await_interrupt(%{state | sent: true}, pending_line)
          false -> finish_interrupt(state, :interrupt_unconfirmed, :write_not_accepted)
        end
      rescue
        ArgumentError -> finish_interrupt(state, :interrupt_unconfirmed, :port_closed)
      end

    {:error, {:turn_interrupt, result}}
  end

  defp await_interrupt(%{response: true, terminal: true} = state, _pending) do
    case resolve_turn_receipt(state.active.receipt) do
      :ok -> finish_interrupt(state, :interrupt_confirmed, :interrupted)
      _ -> finish_interrupt(state, :interrupt_unconfirmed, :receipt_write_failed)
    end
  end

  defp await_interrupt(state, pending) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 -> finish_interrupt(state, :interrupt_unconfirmed, :timeout)
      byte_size(pending) > @port_line_bytes -> finish_interrupt(state, :interrupt_unconfirmed, :message_too_large)
      true -> receive_interrupt(state, pending, remaining)
    end
  end

  defp receive_interrupt(state, pending, remaining) do
    port = state.active.port

    receive do
      {:interrupt_turn, caller, ref, issue_id} ->
        if issue_id == state.active.issue_id do
          await_interrupt(%{state | callers: [{caller, ref} | state.callers]}, pending)
        else
          send(caller, {:interrupt_result, ref, %{status: :interrupt_unconfirmed, reason: :wrong_issue}})
          await_interrupt(state, pending)
        end

      {^port, {:data, {:noeol, bytes}}} ->
        await_interrupt(state, pending <> to_string(bytes))

      {^port, {:data, {:eol, bytes}}} ->
        data = pending <> to_string(bytes)

        if byte_size(data) > @port_line_bytes do
          finish_interrupt(state, :interrupt_unconfirmed, :message_too_large)
        else
          handle_interrupt_payload(state, Jason.decode(data))
        end

      {^port, {:exit_status, _status}} ->
        finish_interrupt(state, :interrupt_unconfirmed, :port_exit)
    after
      remaining -> finish_interrupt(state, :interrupt_unconfirmed, :timeout)
    end
  end

  defp handle_interrupt_payload(state, {:ok, %{"id" => id} = payload}) when id == state.request_id do
    case payload do
      %{"error" => _} -> finish_interrupt(state, :interrupt_unconfirmed, :request_error)
      %{"result" => result} when is_map(result) -> await_interrupt(%{state | response: true}, "")
      _ -> finish_interrupt(state, :interrupt_unconfirmed, :invalid_response)
    end
  end

  defp handle_interrupt_payload(state, {:ok, %{"method" => "turn/completed", "params" => params}}) do
    if matching_turn?(params) do
      case params do
        %{"turn" => %{"status" => "interrupted"}} -> await_interrupt(%{state | terminal: true}, "")
        _ -> finish_interrupt(state, :interrupt_unconfirmed, :terminal_not_interrupted)
      end
    else
      await_interrupt(state, "")
    end
  end

  defp handle_interrupt_payload(state, _payload), do: await_interrupt(state, "")

  defp finish_interrupt(state, status, reason) do
    result = %{
      status: status,
      reason: reason,
      thread_id: state.active.thread_id,
      turn_id: state.active.turn_id,
      issue_id: state.active.issue_id,
      app_server_session: state.active.receipt.session,
      confirmed_at: DateTime.utc_now()
    }

    # Preserve a bounded, secret-free protocol receipt independently of local lease/drain evidence.
    write_receipt(state.active.receipt.path <> ".interrupt", Jason.encode!(result))
    Enum.each(state.callers, fn {caller, ref} -> send(caller, {:interrupt_result, ref, result}) end)
    emit_message(state.on_message, :interrupt_result, result, %{})
    result
  end

  defp matching_turn?(%{"threadId" => thread, "turn" => %{"id" => turn}}) do
    case Process.get(@active_turn_key) do
      %{thread_id: ^thread, turn_id: ^turn} when is_binary(turn) -> true
      _ -> false
    end
  end

  defp matching_turn?(_), do: false

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        handle_turn_completed(on_message, payload, payload_string, port)

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp handle_turn_completed(on_message, payload, payload_string, port) do
    params = Map.get(payload, "params")

    {event, result, details} =
      if matching_turn?(params) and known_terminal_status?(params) do
        case resolve_turn_receipt(Process.get(@active_turn_key).receipt) do
          :ok -> terminal_result(params, payload)
          _ -> unconfirmed_terminal(params)
        end
      else
        unconfirmed_terminal(params)
      end

    emit_turn_event(on_message, event, payload, payload_string, port, details)
    result
  end

  defp known_terminal_status?(%{"turn" => %{"status" => status}}), do: status in ["completed", "failed", "interrupted"]
  defp known_terminal_status?(_params), do: false

  defp terminal_result(%{"turn" => %{"status" => "completed"}}, payload), do: {:turn_completed, {:ok, :turn_completed}, payload}
  defp terminal_result(%{"turn" => %{"status" => "failed"}} = params, _payload), do: {:turn_failed, {:error, {:turn_failed, params}}, params}
  defp terminal_result(%{"turn" => %{"status" => "interrupted"}} = params, _payload), do: {:turn_cancelled, {:error, {:turn_cancelled, params}}, params}
  defp unconfirmed_terminal(params), do: {:turn_failed, {:error, {:turn_completion_unconfirmed, params}}, params}

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
