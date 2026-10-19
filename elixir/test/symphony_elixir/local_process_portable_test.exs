defmodule SymphonyElixir.LocalProcessPortableTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.LocalProcess

  # This scripted helper tests only the Elixir port/control contract. It does not
  # certify Linux ownership, namespace isolation, cleanup, or recovery.
  setup do
    root = Path.join(System.tmp_dir!(), "portable-process-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_path = System.get_env("PATH")
    helper = Path.join(root, "python3")

    File.write!(helper, """
    #!/bin/sh
    case "$4" in
      run)
        case "$6" in
          complete) printf 'portable-output\n' ;;
          fail) printf 'portable-failure\n'; exit 73 ;;
          wait) read -r input; exit 0 ;;
          *) exit 99 ;;
        esac
        ;;
      recover|snapshot)
        case "$5" in
          */refuse) printf 'fixture-blocked\n' >&2; exit 73 ;;
        esac
        ;;
      *) exit 99 ;;
    esac
    """)

    File.chmod!(helper, 0o700)
    System.put_env("PATH", root)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf!(root)
    end)

    {:ok, workspace: root}
  end

  test "port contract returns helper output and a confirmed zero exit", %{workspace: root} do
    assert {:ok, {"portable-output\n", 0}} = LocalProcess.run("complete", root, 1_000)
  end

  test "port contract preserves a nonzero exit rather than converting it to success", %{workspace: root} do
    assert {:ok, {"portable-failure\n", 73}} = LocalProcess.run("fail", root, 1_000)
  end

  test "silent helper times out instead of reporting completion", %{workspace: root} do
    assert {:error, :timeout} = LocalProcess.run("wait", root, 20)
  end

  test "control errors remain errors through snapshot and drain deadline", %{workspace: root} do
    blocked = Path.join(root, "refuse")
    assert {:error, {:local_process_no_go, 73, "fixture-blocked\n"}} = LocalProcess.recover(blocked)
    assert {:error, {:local_process_no_go, 73, "fixture-blocked\n"}} = LocalProcess.snapshot(blocked)
    assert {:error, {:local_process_no_go, 73, "fixture-blocked\n"}} = LocalProcess.drain(blocked)
  end
end
