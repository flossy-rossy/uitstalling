defmodule Uitstalling.Decks.Agent.ContextTest do
  use ExUnit.Case, async: true

  alias Uitstalling.Decks.Agent.Context

  describe "extract_json/1" do
    test "accepts a bare JSON object" do
      assert {:ok, %{"a" => 1}} = Context.extract_json(~s({"a": 1}))
    end

    test "accepts a fenced object, with or without a language tag" do
      assert {:ok, %{"a" => 1}} = Context.extract_json("```json\n{\"a\": 1}\n```")
      assert {:ok, %{"a" => 1}} = Context.extract_json("```\n{\"a\": 1}\n```")
    end

    test "accepts prose around a fenced object" do
      text = "Here is the slide you asked for:\n```json\n{\"a\": 1}\n```\nHope that helps!"
      assert {:ok, %{"a" => 1}} = Context.extract_json(text)
    end

    test "accepts prose around an UNFENCED object (brace-span fallback)" do
      text = ~s(Sure! Here's the updated slide: {"layout": "statement", "body": "hi"} — done.)
      assert {:ok, %{"layout" => "statement"}} = Context.extract_json(text)
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
               Context.extract_json(text)
    end

    test "a truncated object is invalid JSON, not a crash" do
      assert {:error, {:invalid_json, _}} = Context.extract_json(~s({"a": 1, "b":))
    end

    test "a JSON array is rejected as not-an-object" do
      assert {:error, :not_an_object} = Context.extract_json("[1, 2, 3]")
    end

    test "pure prose is invalid JSON" do
      assert {:error, {:invalid_json, _}} = Context.extract_json("I can't produce that slide.")
    end
  end

  describe "prompts" do
    test "edit context prompt uses the deck voice when set" do
      assert Context.edit_context_prompt(%{"voice" => "dry, academic"}) =~ "dry, academic"
    end

    test "edit context prompt tells the model to infer a missing voice" do
      assert Context.edit_context_prompt(%{}) =~ "infer the voice"
      refute Context.edit_context_prompt(%{}) =~ "punchy, technical, confident"
    end

    test "retry prompt carries the rejected attempt and the errors" do
      prompt =
        Context.edit_user_prompt(
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
        Context.edit_user_prompt(
          %{},
          %{"slide_id" => "s1", "layout" => "statement", "prompt" => "fix it"},
          nil
        )

      refute prompt =~ "previous attempt"
    end

    test "create prompt grounds in uploaded research when present" do
      request = %{
        "theme" => "noir",
        "accent" => "amber",
        "voice" => "dry",
        "minutes" => 10,
        "target_slides" => 8,
        "prompt" => "passkeys",
        "research" => "Chrome 67 shipped WebAuthn in 2018.",
        "research_filename" => "sources.docx"
      }

      prompt = Context.create_user_prompt(request, nil)
      assert prompt =~ "<research>"
      assert prompt =~ "Chrome 67 shipped WebAuthn in 2018."
      assert prompt =~ "sources.docx"

      refute Context.create_user_prompt(Map.drop(request, ~w(research)), nil) =~ "<research>"
    end

    test "edit prompts anchor the slide in its section when it has a kicker" do
      deck = %{
        "slides" => [%{"id" => "s1", "layout" => "statement", "kicker" => "§ 2 · WHY IT WORKS"}]
      }

      request = %{"slide_id" => "s1", "layout" => "statement", "prompt" => "fix it"}

      assert Context.edit_user_prompt(deck, request, nil) =~ "§ 2 · WHY IT WORKS"
      assert Context.ops_user_prompt(deck, request, nil) =~ "§ 2 · WHY IT WORKS"
      refute Context.edit_user_prompt(%{}, request, nil) =~ "section"
    end
  end
end
