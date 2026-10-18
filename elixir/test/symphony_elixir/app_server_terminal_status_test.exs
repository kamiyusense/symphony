defmodule SymphonyElixir.AppServerTerminalStatusTest do
  use SymphonyElixir.TestSupport

  test "explicit completed status succeeds and preserves normal protocol events" do
    payload = completion("completed")

    notification = %{
      "method" => "item/agentMessage/delta",
      "params" => %{
        "threadId" => "thread-terminal",
        "turnId" => "turn-terminal",
        "delta" => "Done"
      }
    }

    assert {:ok,
            %{
              result: :turn_completed,
              thread_id: "thread-terminal",
              turn_id: "turn-terminal",
              session_id: "thread-terminal-turn-terminal"
            }} = run_fake(payload, [notification])

    assert_received {:app_server_message,
                     %{
                       event: :session_started,
                       thread_id: "thread-terminal",
                       turn_id: "turn-terminal"
                     }}

    assert_received {:app_server_message, %{event: :notification, payload: ^notification, raw: notification_raw}}

    assert Jason.decode!(notification_raw) == notification

    assert_received {:app_server_message, %{event: :turn_completed, payload: ^payload, details: ^payload, raw: raw}}

    assert Jason.decode!(raw) == payload
    refute_received {:app_server_message, %{event: :turn_ended_with_error}}
    refute_received {:app_server_message, %{event: :turn_failed}}
  end

  for {status, event, reason} <- [
        {"failed", :turn_failed, :turn_failed},
        {"interrupted", :turn_cancelled, :turn_cancelled},
        {"unexpected", :turn_failed, :turn_completion_unconfirmed},
        {nil, :turn_failed, :turn_completion_unconfirmed},
        {42, :turn_failed, :turn_completion_unconfirmed},
        {%{"value" => "completed"}, :turn_failed, :turn_completion_unconfirmed},
        {["completed"], :turn_failed, :turn_completion_unconfirmed}
      ] do
    test "terminal status #{inspect(status)} cannot produce false success" do
      payload = completion(unquote(Macro.escape(status)))
      assert_error(payload, unquote(event), unquote(reason))
    end
  end

  test "missing status cannot produce success" do
    payload = completion("completed") |> update_in(["params", "turn"], &Map.delete(&1, "status"))
    assert_error(payload, :turn_failed, :turn_completion_unconfirmed)
  end

  test "missing or malformed turn and result information cannot produce success" do
    for payload <- [
          %{"method" => "turn/completed"},
          %{"method" => "turn/completed", "params" => %{}},
          %{"method" => "turn/completed", "params" => %{"threadId" => "thread-terminal"}},
          %{"method" => "turn/completed", "params" => nil},
          %{"method" => "turn/completed", "params" => []},
          %{"method" => "turn/completed", "params" => %{"turn" => nil}},
          %{"method" => "turn/completed", "params" => %{"turn" => "completed"}},
          %{
            "method" => "turn/completed",
            "params" => %{"threadId" => "thread-terminal", "turn" => %{"status" => "completed"}}
          },
          %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"id" => "turn-terminal", "status" => "completed"}}
          },
          %{
            "method" => "turn/completed",
            "params" => %{
              "threadId" => "",
              "turn" => %{"id" => "turn-terminal", "status" => "completed"}
            }
          },
          %{
            "method" => "turn/completed",
            "params" => %{
              "threadId" => "thread-terminal",
              "turn" => %{"id" => nil, "status" => "completed"}
            }
          },
          %{"method" => "turn/completed", "result" => %{"turn" => %{"status" => "completed"}}}
        ] do
      assert_error(payload, :turn_failed, :turn_completion_unconfirmed)
    end
  end

  defp completion(status) do
    %{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => "thread-terminal",
        "turn" => %{"id" => "turn-terminal", "status" => status, "items" => []}
      }
    }
  end

  defp assert_error(payload, event, reason) do
    params = Map.get(payload, "params")
    assert {:error, {^reason, ^params}} = run_fake(payload)

    assert_received {:app_server_message, %{event: ^event, payload: ^payload, details: ^params, raw: raw}}

    assert Jason.decode!(raw) == payload

    assert_received {:app_server_message, %{event: :turn_ended_with_error, reason: {^reason, ^params}}}

    refute_received {:app_server_message, %{event: :turn_completed}}
  end

  defp run_fake(payload, notifications \\ []) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-terminal-status-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TERMINAL")
      fake_server = Path.join(test_root, "fake-app-server.py")
      File.mkdir_p!(workspace)

      # Embed JSON as an encoded JSON string so every malformed protocol shape stays data.
      messages = Jason.encode!(Jason.encode!(notifications ++ [payload]))

      File.write!(fake_server, """
      import json
      import sys

      messages = json.loads(#{messages})

      def emit(message):
          print(json.dumps(message), flush=True)

      for line in sys.stdin:
          request = json.loads(line)
          method = request.get("method")
          if method == "initialize":
              emit({"id": request["id"], "result": {}})
          elif method == "initialized":
              continue
          elif method == "thread/start":
              emit({"id": request["id"], "result": {"thread": {"id": "thread-terminal"}}})
          elif method == "turn/start":
              emit({"id": request["id"], "result": {"turn": {"id": "turn-terminal"}}})
              for message in messages:
                  emit(message)
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "python3 -u '#{fake_server}'",
        codex_turn_timeout_ms: 1_000,
        codex_read_timeout_ms: 1_000
      )

      issue = %Issue{
        id: "issue-terminal",
        identifier: "MT-TERMINAL",
        title: "Terminal status regression",
        state: "In Progress"
      }

      test_pid = self()

      AppServer.run(workspace, "Check terminal status", issue, on_message: fn message -> send(test_pid, {:app_server_message, message}) end)
    after
      File.rm_rf(test_root)
    end
  end
end
