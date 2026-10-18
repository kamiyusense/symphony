defmodule SymphonyElixir.LocalProcessTest do
  use ExUnit.Case, async: false

  test "local Linux ownership, stop, crash, recovery and preservation regressions" do
    script = Path.expand("../local_process_test.py", __DIR__)
    evidence = System.get_env("ONE_TASK_EVIDENCE")
    env = if evidence, do: [{"SYMPHONY_PROCESS_TEST_ROOT", evidence}], else: []
    {output, status} = System.cmd("python3", ["-B", script], stderr_to_stdout: true, env: env)

    if evidence do
      File.write!(Path.join(evidence, "local-process-tests.txt"), output, [:exclusive])
    end

    assert status == 0, output
  end

  test "missing Python fails closed for launch, control and the drain deadline" do
    alias SymphonyElixir.LocalProcess
    previous_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", previous_path) end)
    System.put_env("PATH", "/no-such-build-tool-directory")

    assert {:error, :local_process_python_missing} = LocalProcess.open("/tmp", "true")
    assert {:error, :local_process_python_missing} = LocalProcess.run("true", "/tmp", 100)
    assert {:error, :local_process_python_missing} = LocalProcess.recover("/tmp")
    assert {:error, :local_process_python_missing} = LocalProcess.snapshot("/tmp")
    assert {:error, :local_process_python_missing} = LocalProcess.drain("/tmp")
  end

  test "a closed port still requires confirmed ownership drain" do
    alias SymphonyElixir.LocalProcess
    root = Path.join(System.tmp_dir!(), "closed-local-port-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    port = Port.open({:spawn_executable, ~c"/usr/bin/true"}, [:exit_status])
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert Port.info(port) == nil
    assert :ok = LocalProcess.stop(port, root)
    assert :ok = LocalProcess.recover(root)
  end
end
