defmodule Uitstalling.Writing.RotationTest do
  # async: false — swaps the global key-ring config to simulate a rotation.
  use Uitstalling.DataCase, async: false

  import Uitstalling.Fixtures

  alias Uitstalling.Writing

  @ring Application.compile_env!(:uitstalling, :writing_master_keys)
  [active_entry, retired_entry] = String.split(@ring, ",")
  @active_entry active_entry
  @retired_entry retired_entry

  test "rotate_project_keys! re-wraps DEKs; content decrypts before and after" do
    # A project created while the (now-retired) t1 key was active…
    Application.put_env(:uitstalling, :writing_master_keys, @retired_entry)
    on_exit(fn -> Application.put_env(:uitstalling, :writing_master_keys, @ring) end)

    %{user: user, project: project} = writing_project_fixture(title: "Rotated")
    {:ok, doc_id} = Writing.create_doc(project, "chapter", "One")
    assert project.kek_id == "t1"

    # …still opens once the ring rotates (t2 active, t1 retired-but-present).
    Application.put_env(:uitstalling, :writing_master_keys, @ring)
    assert {_raw, 1, "One"} = Writing.checkout_doc(project, doc_id)

    assert Writing.rotate_project_keys!() == 1
    project = Writing.get_project!(project.id, user.id)
    assert project.kek_id == "t2"

    # Nothing rotated twice, everything still decrypts.
    assert Writing.rotate_project_keys!() == 0
    assert Writing.project_title(project) == "Rotated"
    assert {_raw, 1, "One"} = Writing.checkout_doc(project, doc_id)

    # With t1 dropped from the ring entirely, the rotated project is fine.
    Application.put_env(:uitstalling, :writing_master_keys, @active_entry)
    assert {_raw, 1, "One"} = Writing.checkout_doc(project, doc_id)
  end
end
