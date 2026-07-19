defmodule Uitstalling.HTTPTest do
  # async: false — mutates global agent config and the shared Req.Test stub
  use ExUnit.Case, async: false

  alias Uitstalling.Decks.Agent.Claude

  @deck %{"voice" => "dry", "slides" => [%{"id" => "s0", "layout" => "statement", "body" => "x"}]}
  @request %{"slide_id" => "s0", "layout" => "statement", "prompt" => "reword"}

  @reply %{
    "content" => [
      %{"type" => "text", "text" => ~s({"layout": "statement", "body": "rewritten"})}
    ],
    "stop_reason" => "end_turn"
  }

  setup do
    previous = Application.get_env(:uitstalling, :agent_api_key)
    Application.put_env(:uitstalling, :agent_api_key, "test-key")
    on_exit(fn -> Application.put_env(:uitstalling, :agent_api_key, previous) end)

    calls = start_supervised!({Agent, fn -> 0 end})
    %{calls: calls}
  end

  defp count!(calls), do: Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

  test "a dropped connection is retried and the retry's answer wins", %{calls: calls} do
    Req.Test.stub(Uitstalling.ProviderStub, fn conn ->
      case count!(calls) do
        1 -> Req.Test.transport_error(conn, :closed)
        _ -> Req.Test.json(conn, @reply)
      end
    end)

    assert {:ok, %{"body" => "rewritten"}} = Claude.generate_slide(@deck, @request, nil)
    assert Agent.get(calls, & &1) == 2
  end

  test "an overloaded provider (529) is retried", %{calls: calls} do
    Req.Test.stub(Uitstalling.ProviderStub, fn conn ->
      case count!(calls) do
        1 -> conn |> Plug.Conn.put_status(529) |> Req.Test.json(%{"error" => "overloaded"})
        _ -> Req.Test.json(conn, @reply)
      end
    end)

    assert {:ok, %{"body" => "rewritten"}} = Claude.generate_slide(@deck, @request, nil)
    assert Agent.get(calls, & &1) == 2
  end

  test "retries are bounded — a persistently broken provider still fails", %{calls: calls} do
    Req.Test.stub(Uitstalling.ProviderStub, fn conn ->
      count!(calls)
      Req.Test.transport_error(conn, :closed)
    end)

    assert {:error, {:http_error, %Req.TransportError{reason: :closed}}} =
             Claude.generate_slide(@deck, @request, nil)

    # 1 original + 2 retries
    assert Agent.get(calls, & &1) == 3
  end

  test "a 400 is NOT retried — the request is wrong, not unlucky", %{calls: calls} do
    Req.Test.stub(Uitstalling.ProviderStub, fn conn ->
      count!(calls)
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad request"})
    end)

    assert {:error, {:api_error, 400, _body}} = Claude.generate_slide(@deck, @request, nil)
    assert Agent.get(calls, & &1) == 1
  end
end
