defmodule Uitstalling.Decks.Agent.ClaudeTest do
  use ExUnit.Case, async: true

  alias Uitstalling.Decks.Agent.Claude

  describe "extract_json/1" do
    test "accepts a bare JSON object" do
      assert {:ok, %{"a" => 1}} = Claude.extract_json(~s({"a": 1}))
    end

    test "accepts a fenced object, with or without a language tag" do
      assert {:ok, %{"a" => 1}} = Claude.extract_json("```json\n{\"a\": 1}\n```")
      assert {:ok, %{"a" => 1}} = Claude.extract_json("```\n{\"a\": 1}\n```")
    end

    test "accepts prose around a fenced object" do
      text = "Here is the slide you asked for:\n```json\n{\"a\": 1}\n```\nHope that helps!"
      assert {:ok, %{"a" => 1}} = Claude.extract_json(text)
    end

    test "accepts prose around an UNFENCED object (brace-span fallback)" do
      text = ~s(Sure! Here's the updated slide: {"layout": "statement", "body": "hi"} — done.)
      assert {:ok, %{"layout" => "statement"}} = Claude.extract_json(text)
    end

    test "prefers the LARGEST decodable object — narration examples don't win" do
      text = """
      Here's a tiny example of the shape:
      ```json
      {"layout": "statement"}
      ```
      And the actual slide you asked for:
      ```json
      {"layout": "statement", "body": "the real, much longer payload wins"}
      ```
      """

      assert {:ok, %{"body" => "the real, much longer payload wins"}} =
               Claude.extract_json(text)
    end

    test "a truncated object is invalid JSON, not a crash" do
      assert {:error, {:invalid_json, _}} = Claude.extract_json(~s({"a": 1, "b":))
    end

    test "a JSON array is rejected as not-an-object" do
      assert {:error, :not_an_object} = Claude.extract_json("[1, 2, 3]")
    end

    test "pure prose is invalid JSON" do
      assert {:error, {:invalid_json, _}} = Claude.extract_json("I can't produce that slide.")
    end
  end

  describe "prompts" do
    test "edit context prompt uses the deck voice when set" do
      assert Claude.edit_context_prompt(%{"voice" => "dry, academic"}) =~ "dry, academic"
    end

    test "edit context prompt tells the model to infer a missing voice" do
      assert Claude.edit_context_prompt(%{}) =~ "infer the voice"
      refute Claude.edit_context_prompt(%{}) =~ "punchy, technical, confident"
    end

    test "retry prompt carries the rejected attempt and the errors" do
      prompt =
        Claude.edit_user_prompt(
          %{},
          %{"slide_id" => "s1", "layout" => "statement", "prompt" => "fix it"},
          %{
            errors: ["slide.body: required non-empty string"],
            previous: %{"layout" => "statement"}
          }
        )

      assert prompt =~ "Your previous attempt was:"
      assert prompt =~ ~s({"layout":"statement"})
      assert prompt =~ "slide.body: required non-empty string"
      assert prompt =~ "Fix ONLY what the errors require"
    end

    test "first-attempt prompt has no retry block" do
      prompt =
        Claude.edit_user_prompt(
          %{},
          %{"slide_id" => "s1", "layout" => "statement", "prompt" => "fix it"},
          nil
        )

      refute prompt =~ "previous attempt"
    end

    test "edit prompts anchor the slide in its section when it has a kicker" do
      deck = %{
        "slides" => [%{"id" => "s1", "layout" => "statement", "kicker" => "§ 2 · WHY IT WORKS"}]
      }

      request = %{"slide_id" => "s1", "layout" => "statement", "prompt" => "fix it"}

      assert Claude.edit_user_prompt(deck, request, nil) =~ "§ 2 · WHY IT WORKS"
      assert Claude.ops_user_prompt(deck, request, nil) =~ "§ 2 · WHY IT WORKS"
      refute Claude.edit_user_prompt(%{}, request, nil) =~ "section"
    end
  end
end
