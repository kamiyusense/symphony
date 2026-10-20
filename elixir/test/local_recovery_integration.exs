Logger.configure(level: :warning)
for app <- [:logger, :crypto, :jason, :yaml_elixir, :solid, :ecto, :req], do: Application.ensure_all_started(app)
source = Path.expand("../lib", __DIR__)
Code.compiler_options(ignore_module_conflict: true)
{:ok, _, _} = Kernel.ParallelCompiler.compile(Path.wildcard(Path.join(source, "symphony_elixir/**/*.ex")) ++ [Path.join(source, "symphony_elixir.ex")], return_diagnostics: true)
false = File.exists?("/codex")
true = is_nil(System.find_executable("codex"))
SymphonyElixir.Workflow.set_workflow_file_path(System.fetch_env!("ONE_TASK_WORKFLOW"))
evidence = System.fetch_env!("ONE_TASK_EVIDENCE")
root = Path.dirname(evidence)
workspace = Path.join([root, "workspaces", "OFFLINE-RECOVERY"])
File.mkdir_p!(workspace)

wait = fn fun ->
  Enum.reduce_while(1..500, nil, fn _, _ ->
    case fun.() do
      nil ->
        Process.sleep(10)
        {:cont, nil}

      false ->
        Process.sleep(10)
        {:cont, nil}

      value ->
        {:halt, value}
    end
  end)
end

hooks = fn ->
  case File.read(Path.join(evidence, "hooks.jsonl")) do
    {:ok, text} -> String.split(text, "\n", trim: true) |> Enum.map(&Jason.decode!/1)
    _ -> []
  end
end

lease_path = fn ws -> Path.join([Path.dirname(ws), ".symphony-processes", Base.encode16(:crypto.hash(:sha256, ws), case: :lower), "lease.json"]) end
pid_for = fn ws -> Jason.decode!(File.read!(lease_path.(ws)))["process"]["pid"] end

alive = fn pid ->
  case File.read("/proc/#{pid}/stat") do
    {:ok, text} -> (text |> String.split(") ", parts: 2) |> List.last() |> String.first()) not in [nil, "Z"]
    _ -> false
  end
end

marker = Path.join(evidence, "lock-held")

locker = """
import sys
from pathlib import Path
sys.path.insert(0,sys.argv[3])
from local_process import Lease
lease=Lease(sys.argv[1])
Path(sys.argv[2]).write_text('held')
sys.stdin.buffer.read()
"""

port = Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [:binary, :exit_status, args: Enum.map(["-B", "-c", locker, workspace, marker, Path.expand("../priv", __DIR__)], &String.to_charlist/1)])
true = wait.(fn -> File.exists?(marker) end)
issue = %SymphonyElixir.Tracker.Issue{id: "offline-gated", identifier: "OFFLINE-RECOVERY", title: "no-model gate", state: "open", dispatchable: true}
Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
{:ok, runtime} = SymphonyElixir.AgentRuntimeSupervisor.start_link([])
Process.sleep(200)
state = :sys.get_state(SymphonyElixir.Orchestrator)
no_workers = Task.Supervisor.children(SymphonyElixir.TaskSupervisor) == []
blocked = map_size(state.running) == 0 and no_workers and hooks.() == []
true = blocked
Port.close(port)

[first] =
  wait.(fn ->
    case hooks.() do
      [x] -> [x]
      _ -> nil
    end
  end)

first_pid = pid_for.(first["workspace"])
Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "closed"}])
true = wait.(fn -> not File.exists?(workspace) end)
first_stopped = not alive.(first_pid)
snapshots = Path.wildcard(Path.join([root, "workspaces", ".symphony-processes", "*", "snapshot-*.tar"]))
true = snapshots != []
next = %{issue | id: "offline-next", identifier: "OFFLINE-NEXT", state: "open"}
Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "closed"}, next])

second =
  wait.(fn ->
    case hooks.() do
      [_, x] -> x
      _ -> nil
    end
  end)

true = is_map(second)
second_pid = pid_for.(second["workspace"])
:ok = Supervisor.stop(runtime, :normal)
second_stopped = not alive.(second_pid)

result = %{
  pass: blocked and first_stopped and second_stopped,
  unconfirmed_owner_blocked_worker_creation: blocked,
  new_mock_issue_processed_after_stop: second["workspace"] != workspace,
  first_namespace_stopped_before_cleanup: first_stopped,
  second_namespace_stopped_when_supervisor_stop_returned: second_stopped,
  snapshots_saved_before_workspace_deletion: snapshots,
  actual_namespace_pids: [first_pid, second_pid],
  models: 0,
  github_writes: 0
}

File.write!(Path.join(evidence, "result.json"), Jason.encode!(result), [:exclusive])
IO.puts(Jason.encode!(result))
true = result.pass
