defmodule ClaudeControlPlane.ReleaseTest do
  use ClaudeControlPlane.DataCase, async: true

  alias ClaudeControlPlane.Release

  test "create_operator/3 creates the first operator" do
    assert {:ok, operator} =
             Release.create_operator("root@example.com", "Root", "uma senha bem longa")

    assert operator.email == "root@example.com"
  end

  test "create_operator/3 reports invalid data" do
    assert {:error, %Ecto.Changeset{}} = Release.create_operator("bad", "Root", "short")
  end
end
