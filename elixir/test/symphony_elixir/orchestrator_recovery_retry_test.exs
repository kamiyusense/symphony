defmodule SymphonyElixir.OrchestratorRecoveryRetryTest do
  use SymphonyElixir.TestSupport
  @moduletag :os_isolation

  test "an ownership-blocked retry remains scheduled until the workspace is recovered" do
    root = Path.join(System.tmp_dir!(), "recovery-reoffer-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "REOFFER-1")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["open"],
      tracker_terminal_states: ["closed"],
      workspace_root: root,
      poll_interval_ms: 3_600_000,
      max_concurrent_agents: 1,
      codex_command: fake_command(root, "completed"),
      max_turns: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, tasks} = Task.Supervisor.start_link()
    name = Module.concat(__MODULE__, "Retry#{System.unique_integer([:positive])}")
    {:ok, orch} = Orchestrator.start_link(name: name, task_supervisor: tasks)
    :sys.get_state(orch)

    helper = Path.expand("../../priv/local_process.py", __DIR__)

    code =
      "import importlib.util,os,sys; s=importlib.util.spec_from_file_location('owned',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); lease=m.Lease(sys.argv[2]); print('LOCKED',flush=True); sys.stdin.readline(); os.close(lease.fd)"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable("python3"))},
        [:binary, :exit_status, args: ["-B", "-c", code, helper, workspace]]
      )

    assert_receive {^port, {:data, "LOCKED\n"}}, 2_000

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      if Process.alive?(orch), do: GenServer.stop(orch)
      if Process.alive?(tasks), do: Supervisor.stop(tasks)
    end)

    issue = %Issue{id: "reoffer-1", identifier: "REOFFER-1", title: "Known local failure", state: "open", dispatchable: true}

    {:ok, worker} =
      Task.Supervisor.start_child(tasks, fn ->
        receive do
          :stop -> :ok
        end
      end)

    :sys.replace_state(orch, fn state ->
      ref = Process.monitor(worker)

      entry = %{
        pid: worker,
        ref: ref,
        issue: issue,
        identifier: issue.identifier,
        worker_host: nil,
        workspace_path: workspace,
        session_id: nil,
        started_at: DateTime.utc_now(),
        retry_attempt: 0
      }

      %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Process.exit(worker, :kill)

    state =
      wait_until(fn ->
        state = :sys.get_state(orch)
        if Map.has_key?(state.retry_attempts, issue.id), do: state
      end)

    refute MapSet.member?(state.completed, issue.id)
    retry = Map.fetch!(state.retry_attempts, issue.id)
    Process.cancel_timer(retry.timer_ref)
    send(orch, {:retry_issue, issue.id, retry.retry_token})
    state = :sys.get_state(orch)
    assert state.running == %{}
    assert Task.Supervisor.children(tasks) == []
    assert MapSet.member?(state.claimed, issue.id)

    assert Map.has_key?(state.retry_attempts, issue.id),
           "ownership rejection discarded the retry while retaining the claim, stranding the issue"

    refute MapSet.member?(state.completed, issue.id)
    assert state.retry_attempts[issue.id].error =~ "recovery"
    Port.command(port, "release\n")
    assert_receive {^port, {:exit_status, 0}}, 2_000
    retry = state.retry_attempts[issue.id]
    Process.cancel_timer(retry.timer_ref)
    send(orch, {:retry_issue, issue.id, retry.retry_token})
    wait_until(fn -> if length(launches(root)) == 1, do: true end)

    state =
      wait_until(fn ->
        state = :sys.get_state(orch)
        if MapSet.member?(state.completed, issue.id), do: state
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert state.running == %{}
    assert length(launches(root)) == 1
  end

  for status <- ["failed", "interrupted", "unknown"] do
    @status status
    test "a #{@status} worker is not successful and the same active issue can retry after recovery" do
      root = Path.join(System.tmp_dir!(), "recovery-outcome-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["open"],
        tracker_terminal_states: ["closed"],
        workspace_root: root,
        poll_interval_ms: 3_600_000,
        max_concurrent_agents: 1,
        max_turns: 1,
        codex_command: fake_command(root, @status)
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {:ok, tasks} = Task.Supervisor.start_link()
      name = Module.concat(__MODULE__, "Outcome#{System.unique_integer([:positive])}")
      {:ok, orch} = Orchestrator.start_link(name: name, task_supervisor: tasks)

      on_exit(fn ->
        if Process.alive?(orch), do: GenServer.stop(orch)
        if Process.alive?(tasks), do: Supervisor.stop(tasks)
      end)

      :sys.get_state(orch)
      issue = %Issue{id: "outcome-#{@status}", identifier: "OUTCOME-#{@status}", title: "Offline retry #{@status}", state: "open", dispatchable: true}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      send(orch, :tick)

      state =
        wait_until(
          fn ->
            state = :sys.get_state(orch)
            if Map.has_key?(state.retry_attempts, issue.id), do: state
          end,
          400
        )

      refute MapSet.member?(state.completed, issue.id)
      assert state.running == %{}
      assert Task.Supervisor.children(tasks) == []
      assert length(launches(root)) == 1
      send(orch, :tick)
      state = :sys.get_state(orch)
      assert length(launches(root)) == 1
      retry = state.retry_attempts[issue.id]
      Process.cancel_timer(retry.timer_ref)
      send(orch, {:retry_issue, issue.id, retry.retry_token})

      state =
        wait_until(
          fn ->
            state = :sys.get_state(orch)
            if MapSet.member?(state.completed, issue.id), do: state
          end,
          400
        )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      assert state.running == %{}
      assert Task.Supervisor.children(tasks) == []
      assert length(launches(root)) == 2
    end
  end

  defp launches(root) do
    case File.read(Path.join(root, "launches.jsonl")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp fake_command(root, first_status) do
    script = Path.join(root, "fake_app_server.py")

    File.write!(script, """
    import json,sys,os
    from pathlib import Path
    counter=Path(#{inspect(Path.join(root, "launches.jsonl"))})
    with counter.open('a') as f:
        f.write(json.dumps({'pid':os.getpid()})+'\\n');f.flush();os.fsync(f.fileno())
    count=len(counter.read_text().splitlines())
    for line in sys.stdin:
        q=json.loads(line);m=q['method']
        if m=='initialized':continue
        if m=='initialize':v={}
        elif m=='thread/start':v={'thread':{'id':'thread-'+str(count)}}
        elif m=='turn/start':v={'turn':{'id':'turn-'+str(count)}}
        else:raise RuntimeError('unexpected method')
        print(json.dumps({'id':q['id'],'result':v}),flush=True)
        if m=='turn/start':
            turn={'id':'turn-'+str(count),'items':[]}
            status=#{inspect(first_status)} if count==1 else 'completed'
            if status!='unknown':turn['status']=status
            print(json.dumps({'method':'turn/completed','params':{'threadId':'thread-'+str(count),'turn':turn}}),flush=True)
    """)

    "#{System.find_executable("python3")} -B #{script}"
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("expected orchestrator state was not observed")

  defp wait_until(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end
end
