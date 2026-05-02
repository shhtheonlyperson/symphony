defmodule SymphonyElixir.GitHubTrackerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  setup do
    github_request_fun = Application.get_env(:symphony_elixir, :github_request_fun)

    on_exit(fn ->
      if is_nil(github_request_fun) do
        Application.delete_env(:symphony_elixir, :github_request_fun)
      else
        Application.put_env(:symphony_elixir, :github_request_fun, github_request_fun)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_repo: "owner/repo",
      tracker_active_states: ["codex:ready", "codex:running", "codex:rework"],
      tracker_terminal_states: ["codex:done", "Closed"]
    )

    :ok
  end

  test "github config validates repo and resolves token and repo fallbacks" do
    assert :ok = Config.validate!()
    assert Config.settings!().tracker.endpoint == "https://api.github.com"
    assert Config.settings!().tracker.repo == "owner/repo"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_repo: nil
    )

    assert {:error, :missing_github_repo} = Config.validate!()

    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_github_repository = System.get_env("GITHUB_REPOSITORY")
    System.put_env("GITHUB_TOKEN", "fallback-github-token")
    System.put_env("GITHUB_REPOSITORY", "fallback/repo")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("GITHUB_REPOSITORY", previous_github_repository)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: nil,
      tracker_repo: nil
    )

    assert Config.settings!().tracker.api_key == "fallback-github-token"
    assert Config.settings!().tracker.repo == "fallback/repo"
    assert :ok = Config.validate!()

    repo_env_var = "SYMP_GITHUB_REPO_#{System.unique_integer([:positive])}"
    previous_repo_env = System.get_env(repo_env_var)
    System.put_env(repo_env_var, "env-owner/env-repo")

    on_exit(fn -> restore_env(repo_env_var, previous_repo_env) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "token",
      tracker_repo: "$#{repo_env_var}"
    )

    assert Config.settings!().tracker.repo == "env-owner/env-repo"
    assert :ok = Config.validate!()
  end

  test "github client normalizes issues into orchestrator issue structs" do
    issue =
      GitHubClient.normalize_issue_for_test(%{
        "number" => 42,
        "title" => "Wire Symphony",
        "body" => "Use GitHub Issues",
        "state" => "open",
        "html_url" => "https://github.com/owner/repo/issues/42",
        "labels" => [%{"name" => "codex:ready"}, %{"name" => "P1"}],
        "assignees" => [%{"login" => "shh"}],
        "created_at" => "2026-05-01T12:00:00Z",
        "updated_at" => "2026-05-01T13:00:00Z"
      })

    assert issue.id == "42"
    assert issue.identifier == "GH-42"
    assert issue.title == "Wire Symphony"
    assert issue.description == "Use GitHub Issues"
    assert issue.priority == 1
    assert issue.state == "codex:ready"
    assert issue.labels == ["codex:ready", "p1"]
    assert issue.assignee_id == "shh"
    assert issue.assigned_to_worker

    assert is_nil(
             GitHubClient.normalize_issue_for_test(%{
               "number" => 7,
               "title" => "PR",
               "pull_request" => %{}
             })
           )
  end

  test "github client fetches labeled and closed issues by configured state names" do
    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      send(self(), {:github_request, opts[:method], opts[:url], opts[:params]})

      body =
        case opts[:params] do
          %{labels: "codex:ready"} ->
            [
              %{
                "number" => 1,
                "title" => "Ready",
                "body" => "Implement",
                "state" => "open",
                "labels" => [%{"name" => "codex:ready"}, %{"name" => "P1"}],
                "created_at" => "2026-05-01T12:00:00Z"
              }
            ]

          %{state: "closed"} ->
            [
              %{
                "number" => 2,
                "title" => "Closed",
                "body" => "Done",
                "state" => "closed",
                "labels" => [],
                "created_at" => "2026-05-01T11:00:00Z"
              }
            ]
        end

      {:ok, %{status: 200, body: body}}
    end)

    assert {:ok, [ready, closed]} = GitHubClient.fetch_issues_by_states(["codex:ready", "Closed"])
    assert ready.id == "1"
    assert ready.state == "codex:ready"
    assert closed.id == "2"
    assert closed.state == "Closed"

    assert_receive {:github_request, :get, "https://api.github.com/repos/owner/repo/issues", %{labels: "codex:ready"} = params}
    assert params.state == "open"
    assert_receive {:github_request, :get, "https://api.github.com/repos/owner/repo/issues", %{state: "closed"}}
  end

  test "github client replaces state labels when updating issue state" do
    Process.put(:github_responses, [
      fn opts ->
        assert opts[:method] == :get
        assert opts[:url] == "https://api.github.com/repos/owner/repo/issues/123"

        {:ok,
         %{
           status: 200,
           body: %{
             "number" => 123,
             "title" => "Ready",
             "state" => "open",
             "labels" => [%{"name" => "codex:ready"}]
           }
         }}
      end,
      fn opts ->
        assert opts[:method] == :patch
        assert opts[:json] == %{"state" => "open"}
        {:ok, %{status: 200, body: %{}}}
      end,
      fn opts ->
        assert opts[:method] == :delete
        assert opts[:url] == "https://api.github.com/repos/owner/repo/issues/123/labels/codex%3Aready"
        {:ok, %{status: 200, body: []}}
      end,
      fn opts ->
        assert opts[:method] == :post
        assert opts[:url] == "https://api.github.com/repos/owner/repo/issues/123/labels"
        assert opts[:json] == %{"labels" => ["codex:running"]}
        {:ok, %{status: 200, body: []}}
      end
    ])

    Application.put_env(:symphony_elixir, :github_request_fun, fn opts ->
      [response | rest] = Process.get(:github_responses)
      Process.put(:github_responses, rest)
      response.(opts)
    end)

    assert :ok = GitHubClient.update_issue_state("123", "codex:running")
    assert Process.get(:github_responses) == []
  end
end
