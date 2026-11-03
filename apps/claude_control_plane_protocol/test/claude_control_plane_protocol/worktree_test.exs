defmodule ClaudeControlPlaneProtocol.WorktreeTest do
  use ExUnit.Case, async: true

  alias ClaudeControlPlaneProtocol.Worktree

  test "message names" do
    assert Worktree.remove_event() == "worktree:remove"
    assert Worktree.removed_event() == "worktree:removed"
    assert Worktree.usage_event() == "worktree:usage"
  end

  test "a removal names the task and its directory" do
    assert {:ok, %{"task_id" => "t1", "directory" => "app"}} =
             Worktree.parse_remove(%{"task_id" => "t1", "directory" => "app"})

    assert {:error, _} = Worktree.parse_remove(%{"task_id" => "t1", "directory" => "../etc"})
    assert {:error, _} = Worktree.parse_remove(%{"task_id" => "", "directory" => "app"})
    assert {:error, _} = Worktree.parse_remove(%{"task_id" => "../x", "directory" => "app"})
    assert {:error, _} = Worktree.parse_remove(:nope)
  end

  test "usage counts the worktrees, their size and the free space" do
    usage = %{"count" => 2, "bytes" => 1_024, "free_bytes" => 4_096}
    assert Worktree.parse_usage(usage) == {:ok, usage}
    assert {:ok, %{"free_bytes" => nil}} = Worktree.parse_usage(%{usage | "free_bytes" => nil})
    assert {:error, _} = Worktree.parse_usage(%{usage | "count" => -1})
    assert {:error, _} = Worktree.parse_usage(%{"count" => 1})
  end
end
