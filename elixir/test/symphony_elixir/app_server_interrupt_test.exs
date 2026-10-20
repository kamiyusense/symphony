defmodule SymphonyElixir.AppServerInterruptTest do
  use SymphonyElixir.TestSupport
  @moduletag :os_isolation

  for mode <- ["confirmed", "terminal_first", "wrong_then_correct", "fragmented"] do
    test "#{mode}: only the matching response and interrupted terminal confirm" do
      c = start_fake(unquote(mode))
      result = AppServer.interrupt(c.worker, c.issue.id)
      assert result.status == :interrupt_confirmed
      assert result.thread_id == "thread-live"
      assert result.turn_id == "turn-live"
      assert result.issue_id == c.issue.id
      assert_receive {:run_result, {:error, {:turn_interrupt, ^result}}}, 2_000
      assert_sent_once(c)
      assert_local_stopped(c)
      assert :ok = AppServer.recovery_ready(c.workspace)
    end
  end

  for {mode, reason} <- [
        {"response_only", :timeout},
        {"event_only", :timeout},
        {"error", :request_error},
        {"wrong_turn", :request_error},
        {"wrong_event", :timeout},
        {"completed", :terminal_not_interrupted},
        {"malformed", :timeout},
        {"closed", :port_exit},
        {"wrong_response", :timeout},
        {"null_response", :invalid_response},
        {"flood", :timeout},
        {"oversized", :message_too_large}
      ] do
    test "#{mode}: unconfirmed blocks reuse while local cleanup still runs" do
      c = start_fake(unquote(mode))
      result = AppServer.interrupt(c.worker, c.issue.id)
      assert result.status == :interrupt_unconfirmed
      assert result.reason == unquote(reason)
      assert_receive {:run_result, {:error, {:turn_interrupt, ^result}}}, 2_000
      assert_sent_once(c)
      assert_local_stopped(c)
      assert {:error, :interrupt_completion_unconfirmed} = AppServer.recovery_ready(c.workspace)
      assert {:error, :interrupt_completion_unconfirmed} = Workspace.ensure_stopped(c.issue, nil)
      assert {:error, _, _} = Workspace.remove(c.workspace)
      assert File.dir?(c.workspace)
      # A completely new AppServer owner cannot erase the old turn barrier.
      assert {:error, :interrupt_completion_unconfirmed} = AppServer.start_session(c.workspace)
      assert length(requests(c)) == 5
    end
  end

  test "duplicate stop requests share one interrupt; owned detached helper is drained separately" do
    c = start_fake("delayed")
    a = Task.async(fn -> AppServer.interrupt(c.worker, c.issue.id) end)
    b = Task.async(fn -> AppServer.interrupt(c.worker, c.issue.id) end)
    assert Task.await(a).status == :interrupt_confirmed
    assert Task.await(b).status == :interrupt_confirmed
    assert_receive {:run_result, {:error, {:turn_interrupt, _}}}, 2_000
    assert_sent_once(c)
    assert_local_stopped(c)
  end

  test "a wrong Issue cannot interrupt this owner's active turn" do
    c = start_fake("confirmed")
    assert %{status: :interrupt_unconfirmed, reason: :active_turn_unknown} = AppServer.interrupt(c.worker, "other-issue")
    assert requests(c) |> Enum.all?(&(&1["method"] != "turn/interrupt"))
    assert AppServer.interrupt(c.worker, c.issue.id).status == :interrupt_confirmed
    assert_receive {:run_result, _}, 2_000
    assert_sent_once(c)
    assert_local_stopped(c)
  end

  test "a dead owner has no inferred interrupt target" do
    {owner, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    assert %{status: :interrupt_unconfirmed, reason: :owner_down} = AppServer.interrupt(owner, "missing")
    assert %{status: :interrupt_unconfirmed, reason: :owner_missing} = AppServer.interrupt(nil, "missing")
  end

  test "an unresponsive owner is bounded and never a successful interrupt" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    assert %{status: :interrupt_unconfirmed, reason: :owner_unresponsive} = AppServer.interrupt(owner, "missing")
  end

  test "a turn timeout uses the same formal interruption before local stop" do
    c = start_fake("confirmed", 100)
    assert_receive {:run_result, {:error, :turn_timeout}}, 2_000
    assert_receive {:stream, %{event: :interrupt_result, status: :interrupt_confirmed}}
    assert_sent_once(c)
    assert_local_stopped(c)
  end

  test "owner death preserves an unresolved turn across ownership recovery" do
    c = start_fake("confirmed")
    Process.exit(c.worker, :kill)
    assert :ok = SymphonyElixir.LocalProcess.drain(c.workspace)
    assert {:error, :interrupt_completion_unconfirmed} = Workspace.ensure_stopped(c.issue, nil)
  end

  for stop <- [:terminal, :inactive, :routing, :missing, :stall, :shutdown] do
    test "Orchestrator #{stop} uses the owner interrupt then mandatory local drain" do
      c = start_orchestrated("confirmed")
      stop = unquote(stop)

      request_stop(c, stop)
      await_orchestrator_stop(c, stop)

      assert_sent_once(c)
      assert_local_stopped(c)
      assert :ok = AppServer.recovery_ready(c.workspace)
      assert length(Enum.filter(requests(c), &(&1["method"] == "turn/start"))) == 1
    end
  end

  test "Orchestrator retains claim after unconfirmed stop, including terminal/missing and runtime restart" do
    c = start_orchestrated("response_only")
    change_issue(c, %{c.issue | state: "Done"})
    send(c.orch, :tick)

    state =
      wait_until(fn ->
        state = :sys.get_state(c.orch)
        if Map.has_key?(state.blocked, c.issue.id), do: state
      end)

    blocked = state.blocked[c.issue.id]
    assert blocked.interrupt_result.status == :interrupt_unconfirmed
    assert blocked.local_cleanup == :ok
    assert blocked.recovery_blocked
    assert MapSet.member?(state.claimed, c.issue.id)
    assert state.retry_attempts == %{}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    send(c.orch, :tick)
    Process.sleep(40)
    assert Map.has_key?(:sys.get_state(c.orch).blocked, c.issue.id)
    GenServer.stop(c.orch)
    change_issue(c, c.issue)
    {:ok, restarted} = Orchestrator.start_link(name: Module.concat(__MODULE__, "Restart#{System.unique_integer([:positive])}"), task_supervisor: c.tasks)
    Process.unlink(restarted)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    state =
      wait_until(fn ->
        state = :sys.get_state(restarted)
        if Map.has_key?(state.retry_attempts, c.issue.id), do: state
      end)

    assert state.running == %{}
    assert MapSet.member?(state.claimed, c.issue.id)
    assert_sent_once(c)
    assert length(requests(c)) == 5
    assert_local_stopped(c)
  end

  test "no active turn: stopping an owned before_run hook sends no guessed interrupt" do
    c = prepare_case("confirmed", 5_000)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: c.root,
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      poll_interval_ms: 3_600_000,
      hook_before_run: "touch hook-working; sleep 90",
      max_concurrent_agents: 1
    )

    c = start_orchestrated_case(c, false)
    wait_until(fn -> if File.exists?(Path.join(c.workspace, "hook-working")), do: true end)
    change_issue(c, %{c.issue | state: "Done"})
    send(c.orch, :tick)
    wait_until(fn -> :sys.get_state(c.orch).running == %{} end)
    refute File.exists?(Path.join(c.root, "requests.jsonl"))
    assert :ok = SymphonyElixir.LocalProcess.recover(c.workspace)
  end

  defp request_stop(c, stop) do
    case stop do
      :terminal ->
        change_issue(c, %{c.issue | state: "Done"})

      :inactive ->
        change_issue(c, %{c.issue | state: "Backlog"})

      :routing ->
        change_issue(c, %{c.issue | dispatchable: false})

      :missing ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      :stall ->
        :sys.replace_state(c.orch, fn state ->
          entry = state.running[c.issue.id] |> Map.put(:last_codex_timestamp, DateTime.add(DateTime.utc_now(), -600, :second))
          %{state | running: Map.put(state.running, c.issue.id, entry)}
        end)

      :shutdown ->
        GenServer.stop(c.orch)
    end
  end

  defp await_orchestrator_stop(c, stop) do
    if stop != :shutdown do
      send(c.orch, :tick)
      wait_until(fn -> :sys.get_state(c.orch).running == %{} end)
    end
  end

  defp start_orchestrated(mode), do: start_orchestrated_case(prepare_case(mode, 5_000), true)

  defp start_orchestrated_case(c, active?) do
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, tasks} = Task.Supervisor.start_link()
    Process.unlink(tasks)
    {:ok, orch} = Orchestrator.start_link(name: Module.concat(__MODULE__, "Stop#{System.unique_integer([:positive])}"), task_supervisor: tasks)
    Process.unlink(orch)
    :sys.get_state(orch)
    change_issue(c, c.issue)
    send(orch, :tick)

    entry =
      wait_until(fn ->
        entry = Map.get(:sys.get_state(orch).running, c.issue.id)
        if entry && (not active? or entry[:turn_id] == "turn-live"), do: entry
      end)

    c = Map.merge(c, %{orch: orch, tasks: tasks, worker: entry.pid})

    on_exit(fn ->
      if Process.alive?(orch), do: GenServer.stop(orch)
      if Process.alive?(tasks), do: Supervisor.stop(tasks)
      :ok = SymphonyElixir.LocalProcess.drain(c.workspace)
      preserve_case(c)
      File.rm_rf!(c.root)
    end)

    c
  end

  defp change_issue(_c, issue), do: Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

  defp wait_until(fun, tries \\ 400)
  defp wait_until(_fun, 0), do: flunk("expected offline worker state was not observed")

  defp wait_until(fun, tries) do
    case fun.() do
      nil ->
        Process.sleep(10)
        wait_until(fun, tries - 1)

      false ->
        Process.sleep(10)
        wait_until(fun, tries - 1)

      value ->
        value
    end
  end

  defp preserve_case(c) do
    if dir = System.get_env("ONE_TASK_EVIDENCE") do
      File.cp_r!(c.root, Path.join(dir, Path.basename(c.root)))
    end
  end

  test "protocol confirmation leaves an owned helper alive until the separate local cleanup" do
    c = start_fake("hold_cleanup")
    assert AppServer.interrupt(c.worker, c.issue.id).status == :interrupt_confirmed
    assert_receive {:protocol_only, {:error, {:turn_interrupt, _}}}
    [lease_path] = Path.wildcard(Path.join([c.root, ".symphony-processes", "*", "lease.json"]))
    lease = lease_path |> File.read!() |> Jason.decode!()
    assert lease["state"] == "running"
    assert File.exists?("/proc/#{lease["process"]["pid"]}")
    send(c.worker, :allow_cleanup)
    assert_receive {:run_result, _}, 2_000
    assert_local_stopped(c)
  end

  test "another process cannot take over a session's Port reader" do
    c = prepare_case("confirmed", 5_000)
    {:ok, session} = AppServer.start_session(c.workspace)

    try do
      foreign = Task.async(fn -> AppServer.run_turn(session, "No takeover", c.issue) end)
      assert {:error, :session_owner_mismatch} = Task.await(foreign)
      refute Enum.any?(requests(c), &(&1["method"] == "turn/start"))
    after
      :ok = AppServer.stop_session(session)
      preserve_case(c)
      File.rm_rf!(c.root)
    end
  end

  test "missing turn ID never becomes an inferred interrupt target" do
    c = prepare_case("missing_id", 1_000)

    try do
      assert {:error, :invalid_turn_payload} = AppServer.run(c.workspace, "Unknown target", c.issue)
      refute Enum.any?(requests(c), &(&1["method"] == "turn/interrupt"))
      assert :ok = SymphonyElixir.LocalProcess.recover(c.workspace)
      assert {:error, :interrupt_completion_unconfirmed} = AppServer.recovery_ready(c.workspace)
    after
      preserve_case(c)
      File.rm_rf!(c.root)
    end
  end

  test "missing Task Supervisor cannot bypass owned cleanup or stop an unrelated process" do
    c = start_fake("hold_cleanup")
    sentinel = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(sentinel, :kill) end)

    entry = %{
      pid: c.worker,
      ref: Process.monitor(c.worker),
      identifier: c.issue.identifier,
      issue: c.issue,
      workspace_path: c.workspace,
      worker_host: nil,
      session_id: "thread-live-turn-live",
      last_codex_event: :session_started
    }

    state = %Orchestrator.State{running: %{c.issue.id => entry}, task_supervisor: __MODULE__.MissingSupervisor}
    assert :ok = Orchestrator.terminate(:normal, state)
    assert_sent_once(c)
    assert_local_stopped(c)
    assert Process.alive?(sentinel)
  end

  test "shutdown before runtime metadata is consumed cannot clear a live turn's recovery barrier" do
    c = start_fake("confirmed")

    entry = %{
      pid: c.worker,
      ref: Process.monitor(c.worker),
      identifier: c.issue.identifier,
      issue: c.issue,
      # Deliberately omit runtime updates that may still be queued at shutdown.
      session_id: nil
    }

    state = %Orchestrator.State{running: %{c.issue.id => entry}, task_supervisor: __MODULE__.MissingSupervisor}

    assert_raise RuntimeError, "Runtime stop unconfirmed; recovery remains NO-GO", fn ->
      Orchestrator.terminate(:normal, state)
    end

    assert_local_stopped(c)
    assert {:error, :interrupt_completion_unconfirmed} = Workspace.ensure_stopped(c.issue, nil)
    refute Enum.any?(requests(c), &(&1["method"] == "turn/interrupt"))
  end

  defp start_fake(mode, turn_timeout \\ 5_000) do
    c = prepare_case(mode, turn_timeout)
    %{root: root, workspace: workspace, issue: issue} = c
    parent = self()

    worker =
      spawn(fn ->
        opts = [on_message: fn m -> send(parent, {:stream, m}) end]

        result =
          if mode == "hold_cleanup" do
            {:ok, session} = AppServer.start_session(workspace)
            result = AppServer.run_turn(session, "Work locally", issue, opts)
            send(parent, {:protocol_only, result})

            receive do
              :allow_cleanup -> :ok
            end

            :ok = AppServer.stop_session(session)
            result
          else
            AppServer.run(workspace, "Work locally", issue, opts)
          end

        send(parent, {:run_result, result})
      end)

    c = %{root: root, workspace: workspace, worker: worker, issue: issue}

    on_exit(fn ->
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      SymphonyElixir.LocalProcess.drain(workspace)
      preserve_case(c)
      File.rm_rf!(root)
    end)

    assert_receive {:stream, %{event: :session_started, thread_id: "thread-live", turn_id: "turn-live", session_owner: ^worker}}, 3_000
    # Helper existence and event prove work is active before issuing cancellation.
    assert File.exists?(Path.join(root, "helper-ready"))
    c
  end

  defp prepare_case(mode, turn_timeout) do
    root = Path.join(System.tmp_dir!(), "interrupt-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "INT-1")
    File.mkdir_p!(workspace)
    script = Path.join(root, "fake.py")
    File.write!(script, fake_script(root, mode))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      codex_command: "python3 -B -u '#{script}'",
      codex_read_timeout_ms: 150,
      codex_turn_timeout_ms: turn_timeout,
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      poll_interval_ms: 3_600_000,
      max_concurrent_agents: 1,
      max_turns: 1
    )

    issue = %Issue{id: "interrupt-issue", identifier: "INT-1", title: "Offline interrupt", state: "In Progress", dispatchable: true}
    %{root: root, workspace: workspace, issue: issue}
  end

  defp assert_sent_once(c) do
    assert [%{"params" => %{"threadId" => "thread-live", "turnId" => "turn-live"}}] =
             Enum.filter(requests(c), &(&1["method"] == "turn/interrupt"))
  end

  defp assert_local_stopped(c) do
    ref = Process.monitor(c.worker)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    assert :ok = SymphonyElixir.LocalProcess.drain(c.workspace)
    assert :ok = SymphonyElixir.LocalProcess.recover(c.workspace)
    # The lease snapshot checks the owned namespace has actually died, not just the Task.
    assert :ok = SymphonyElixir.LocalProcess.snapshot(c.workspace)
  end

  defp requests(c) do
    Path.join(c.root, "requests.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp fake_script(root, mode) do
    """
    import json,sys,time,subprocess,os
    from pathlib import Path
    root=Path(#{inspect(root)});mode=#{inspect(mode)}
    def emit(data):
        line=json.dumps(data)+'\\n'
        if mode=='fragmented':
            sys.stdout.write(line[:4]);sys.stdout.flush();time.sleep(.005);sys.stdout.write(line[4:]);sys.stdout.flush()
        else:print(line,end='',flush=True)
    def terminal(thread='thread-live',turn='turn-live',status='interrupted'):
        emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':status}}})
    for line in sys.stdin:
        q=json.loads(line)
        with (root/'requests.jsonl').open('a') as f:f.write(json.dumps(q)+'\\n')
        m=q.get('method')
        if m=='initialized':continue
        if m=='initialize':emit({'id':q['id'],'result':{}})
        elif m=='thread/start':emit({'id':q['id'],'result':{'thread':{'id':'thread-live'}}})
        elif m=='turn/start':
            subprocess.Popen([sys.executable,'-c','import time;time.sleep(90)'],start_new_session=True)
            (root/'helper-ready').write_text('working')
            emit({'id':q['id'],'result':{'turn':{'id':'' if mode=='missing_id' else 'turn-live'}}})
        elif m=='turn/interrupt':
            assert q['params']=={'threadId':'thread-live','turnId':'turn-live'}
            if mode=='closed':sys.exit(0)
            if mode in ('error','wrong_turn'):
                emit({'id':q['id'],'error':{'code':-32602,'message':'wrong turn'}});continue
            if mode=='delayed':time.sleep(.05)
            if mode=='terminal_first':terminal()
            if mode=='wrong_then_correct':terminal('other-thread');terminal(turn='other-turn')
            if mode=='null_response':emit({'id':q['id'],'result':None});continue
            if mode=='wrong_response':emit({'id':'another-request','result':{}});terminal();continue
            if mode!='event_only':emit({'id':q['id'],'result':{}})
            if mode=='oversized':print('X'*1100000,flush=True);continue
            if mode=='flood':
                end=time.monotonic()+2
                while time.monotonic()<end:emit({'method':'unrelated','params':{}})
                continue
            if mode=='response_only':continue
            if mode=='wrong_event':terminal(turn='other-turn');continue
            if mode=='completed':terminal(status='completed');continue
            if mode=='malformed':print('not-json',flush=True);continue
            if mode!='terminal_first':terminal()
    """
  end
end
