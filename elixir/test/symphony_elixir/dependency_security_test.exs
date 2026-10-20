defmodule SymphonyElixir.DependencySecurityTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias Plug.Conn.{InvalidQueryError, Query}
  alias SymphonyElixir.Config.Schema.Codex

  test "Req does not automatically unpack an untrusted archive response" do
    {:ok, {_name, archive}} = :zip.create(~c"payload.zip", [{~c"file.txt", "bounded fixture"}], [:memory])

    response =
      Req.get!("http://dependency.test/archive",
        retry: false,
        plug: fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/zip")
          |> Plug.Conn.send_resp(200, archive)
        end
      )

    assert response.status == 200
    assert response.body == archive
  end

  test "Req multipart fields cannot inject headers through names or metadata" do
    response =
      Req.post!("http://dependency.test/upload",
        retry: false,
        form_multipart: [
          {"field\r\nInjected: yes", {"payload", filename: "file\r\nInjected: yes.txt", content_type: "text/plain\r\nInjected: yes"}}
        ],
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Plug.Conn.send_resp(conn, 200, body)
        end
      )

    assert response.body =~ "%0D%0AInjected: yes"
    refute response.body =~ "\r\nInjected: yes"
  end

  test "Req retains JSON decoding and does not retry an authentication rejection" do
    owner = self()

    response =
      Req.get!("http://dependency.test/private",
        retry: false,
        redirect: false,
        plug: fn conn ->
          send(owner, :request_received)

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, ~s({"error":"unauthorized"}))
        end
      )

    assert response.status == 401
    assert response.body == %{"error" => "unauthorized"}
    assert_received :request_received
    refute_received :request_received
  end

  test "LiveView rejects control characters in local redirect destinations" do
    for destination <- ["/\t/attacker.test", "/%09/attacker.test", "/\n/attacker.test", "/\r/attacker.test"] do
      assert_raise ArgumentError, fn -> Phoenix.LiveView.redirect(%Socket{}, to: destination) end
    end
  end

  test "LiveView still accepts a normal local redirect" do
    assert %{redirected: {:redirect, %{to: "/dashboard", status: 302}}} =
             Phoenix.LiveView.redirect(%Socket{}, to: "/dashboard")
  end

  test "Plug bounds query nesting while keeping ordinary nested parameters" do
    assert Query.decode("issue[id]=123") == %{"issue" => %{"id" => "123"}}

    assert_raise InvalidQueryError, fn ->
      Query.decode("issue" <> String.duplicate("[nested]", 40) <> "=value")
    end
  end

  test "Decimal rejects pathological exponents without expanding the value" do
    assert Decimal.cast("1e1000000") == :error
  end

  test "Decimal rejects excessive rounding places before allocation" do
    assert_raise Decimal.Error, fn -> Decimal.round(Decimal.new("1.5"), 1_000_000) end
  end

  test "Solid, Ecto and Jason remain compatible with ordinary decimal values" do
    template = Solid.parse!("{{ amount | plus: 0.25 }}")
    assert template |> Solid.render!(%{"amount" => "1.25"}) |> IO.iodata_to_binary() == "1.5"
    assert {:ok, value} = Ecto.Type.cast(:decimal, "1.25")
    assert Decimal.equal?(value, Decimal.new("1.25"))
    assert Jason.encode!(value) == ~s("1.25")
  end

  test "explicitly blank commands remain invalid after the Ecto update" do
    for command <- ["", "   ", "\t"] do
      changeset = Codex.changeset(%Codex{}, %{"command" => command})
      refute changeset.valid?
      assert {"can't be blank", _metadata} = changeset.errors[:command]
    end

    assert Codex.changeset(%Codex{}, %{}).valid?
    assert Codex.changeset(%Codex{}, %{"command" => "/bin/sh app-server"}).valid?
  end
end
