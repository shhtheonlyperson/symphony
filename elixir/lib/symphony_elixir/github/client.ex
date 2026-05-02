defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for polling GitHub Issues as Symphony tracker work.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 100
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    Config.settings!().tracker.active_states
    |> fetch_issues_by_states()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    state_names
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&normalize_state/1)
    |> fetch_state_issue_sets()
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids = Enum.map(issue_ids, &to_string/1) |> Enum.uniq()

    issue_ids
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case fetch_issue(issue_id) do
        {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} ->
        {:ok, sort_issues_by_requested_ids(Enum.reverse(issues), issue_ids)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case request(:post, issue_path(issue_id, "/comments"), json: %{"body" => body}, expected: [201]) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    normalized_state = normalize_state(state_name)

    with {:ok, issue} <- raw_issue(issue_id),
         :ok <- maybe_update_open_closed_state(issue_id, normalized_state) do
      replace_state_labels(issue_id, issue, state_name, normalized_state)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue), do: normalize_issue(issue)

  defp fetch_state_issue_sets([]), do: {:ok, []}

  defp fetch_state_issue_sets(state_names) do
    state_names
    |> Enum.reduce_while({:ok, %{}}, fn state_name, {:ok, acc} ->
      case fetch_issues_for_state(state_name) do
        {:ok, issues} ->
          {:cont, {:ok, merge_issues(acc, issues)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issue_map} ->
        target_states = Enum.map(state_names, &normalize_state/1) |> MapSet.new()

        issues =
          issue_map
          |> Map.values()
          |> Enum.filter(fn %Issue{state: state} ->
            MapSet.member?(target_states, normalize_state(state))
          end)
          |> Enum.sort_by(&issue_sort_key/1)

        {:ok, issues}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issues_for_state(state_name) do
    case normalize_state(state_name) do
      "closed" -> fetch_paginated_issues(%{state: "closed"})
      _ -> fetch_paginated_issues(%{state: "open", labels: state_name})
    end
  end

  defp fetch_paginated_issues(params) do
    do_fetch_paginated_issues(Map.merge(%{per_page: @issue_page_size}, params), 1, [])
  end

  defp do_fetch_paginated_issues(params, page, acc) do
    params = Map.put(params, :page, page)

    case request(:get, "/issues", params: params, expected: [200]) do
      {:ok, body} when is_list(body) ->
        issues =
          body
          |> Enum.map(&normalize_issue/1)
          |> Enum.reject(&is_nil/1)

        acc = issues ++ acc

        if length(body) == @issue_page_size do
          do_fetch_paginated_issues(params, page + 1, acc)
        else
          {:ok, Enum.reverse(acc)}
        end

      {:ok, _body} ->
        {:error, :github_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issue(issue_id) do
    case raw_issue(issue_id) do
      {:ok, issue} -> {:ok, normalize_issue(issue)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_issue(issue_id) do
    request(:get, issue_path(issue_id), expected: [200])
  end

  defp maybe_update_open_closed_state(issue_id, "closed") do
    patch_issue_state(issue_id, "closed")
  end

  defp maybe_update_open_closed_state(issue_id, _normalized_state) do
    patch_issue_state(issue_id, "open")
  end

  defp patch_issue_state(issue_id, github_state) do
    case request(:patch, issue_path(issue_id), json: %{"state" => github_state}, expected: [200]) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_state_labels(issue_id, issue, state_name, normalized_state) do
    configured_state_labels()
    |> Enum.reject(&(normalize_state(&1) == normalized_state))
    |> Enum.filter(&issue_has_label?(issue, &1))
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case remove_label(issue_id, label) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> maybe_add_state_label(issue_id, state_name, normalized_state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_label(issue_id, label) do
    case request(:delete, issue_path(issue_id, "/labels/#{encode_path_segment(label)}"), expected: [200, 204, 404]) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_state_label(_issue_id, _state_name, "closed"), do: :ok

  defp maybe_add_state_label(issue_id, state_name, _normalized_state) do
    case request(:post, issue_path(issue_id, "/labels"), json: %{"labels" => [state_name]}, expected: [200]) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_issues(issue_map, issues) do
    Enum.reduce(issues, issue_map, fn
      %Issue{id: issue_id} = issue, acc when is_binary(issue_id) -> Map.put(acc, issue_id, issue)
      _issue, acc -> acc
    end)
  end

  defp sort_issues_by_requested_ids(issues, issue_ids) do
    issue_order_index =
      issue_ids
      |> Enum.with_index()
      |> Map.new()

    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp issue_sort_key(%Issue{priority: priority, created_at: %DateTime{} = created_at, id: id}) do
    {priority || 5, DateTime.to_unix(created_at, :microsecond), id || ""}
  end

  defp issue_sort_key(%Issue{priority: priority, id: id}), do: {priority || 5, 9_223_372_036_854_775_807, id || ""}

  defp normalize_issue(%{"pull_request" => _pull_request}), do: nil

  defp normalize_issue(issue) when is_map(issue) do
    labels = extract_label_names(issue)
    assignees = extract_assignees(issue)

    %Issue{
      id: issue["number"] |> to_issue_id(),
      identifier: issue_identifier(issue["number"]),
      title: issue["title"],
      description: issue["body"],
      priority: parse_priority(labels),
      state: issue_state(issue, labels),
      branch_name: nil,
      url: issue["html_url"],
      assignee_id: List.first(assignees),
      blocked_by: [],
      labels: Enum.map(labels, &String.downcase/1),
      assigned_to_worker: assigned_to_worker?(assignees),
      created_at: parse_datetime(issue["created_at"]),
      updated_at: parse_datetime(issue["updated_at"])
    }
  end

  defp normalize_issue(_issue), do: nil

  defp issue_state(%{"state" => "closed"}, _labels), do: configured_closed_state()

  defp issue_state(_issue, labels) do
    configured_state_for_labels(labels) || configured_open_state()
  end

  defp configured_state_for_labels(labels) do
    normalized_labels =
      labels
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    Enum.find(configured_state_labels(), fn state_name ->
      MapSet.member?(normalized_labels, normalize_state(state_name))
    end)
  end

  defp configured_state_labels do
    tracker = Config.settings!().tracker

    (tracker.active_states ++ tracker.terminal_states)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&normalize_state/1)
  end

  defp configured_open_state do
    Config.settings!().tracker.active_states
    |> List.first()
    |> case do
      state when is_binary(state) -> state
      _ -> "Open"
    end
  end

  defp configured_closed_state do
    Config.settings!().tracker.terminal_states
    |> Enum.find(&(normalize_state(&1) == "closed"))
    |> case do
      state when is_binary(state) -> state
      _ -> "Closed"
    end
  end

  defp issue_has_label?(issue, label) when is_map(issue) and is_binary(label) do
    label_set =
      issue
      |> extract_label_names()
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    MapSet.member?(label_set, normalize_state(label))
  end

  defp extract_label_names(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp extract_label_names(_issue), do: []

  defp extract_assignees(%{"assignees" => assignees}) when is_list(assignees) do
    assignees
    |> Enum.flat_map(fn
      %{"login" => login} when is_binary(login) -> [login]
      _ -> []
    end)
  end

  defp extract_assignees(_issue), do: []

  defp assigned_to_worker?(assignees) do
    case Config.settings!().tracker.assignee do
      nil ->
        true

      assignee ->
        normalized_assignee = normalize_state(assignee)
        Enum.any?(assignees, &(normalize_state(&1) == normalized_assignee))
    end
  end

  defp parse_priority(labels) do
    Enum.find_value(labels, fn label ->
      normalized = String.downcase(String.trim(label))

      cond do
        Regex.match?(~r/^p[1-4]$/, normalized) ->
          normalized |> String.trim_leading("p") |> String.to_integer()

        Regex.match?(~r/^priority[:\/ -][1-4]$/, normalized) ->
          normalized |> String.slice(-1, 1) |> String.to_integer()

        true ->
          nil
      end
    end)
  end

  defp to_issue_id(number) when is_integer(number), do: Integer.to_string(number)
  defp to_issue_id(number) when is_binary(number), do: number
  defp to_issue_id(_number), do: nil

  defp issue_identifier(number) when is_integer(number), do: "GH-#{number}"
  defp issue_identifier(number) when is_binary(number), do: "GH-#{number}"
  defp issue_identifier(_number), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp request(method, path, opts) do
    expected = Keyword.get(opts, :expected, [200])
    request_opts = Keyword.drop(opts, [:expected])

    with {:ok, repo} <- tracker_repo(),
         {:ok, headers} <- rest_headers(),
         {:ok, %{status: status, body: body}} <-
           request_fun().(
             [
               method: method,
               url: github_url(repo, path),
               headers: headers,
               connect_options: [timeout: 30_000]
             ] ++ request_opts
           ) do
      if status in expected do
        {:ok, body}
      else
        Logger.error("GitHub REST request failed method=#{method} path=#{path} status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:github_api_status, status}}
      end
    else
      {:error, reason} ->
        Logger.error("GitHub REST request failed method=#{method} path=#{path}: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp request_fun do
    Application.get_env(:symphony_elixir, :github_request_fun, &Req.request/1)
  end

  defp github_url(repo, path) do
    Config.settings!().tracker.endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>("/repos/#{repo}#{path}")
  end

  defp tracker_repo do
    case Config.settings!().tracker.repo do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _ -> {:error, :missing_github_repo}
    end
  end

  defp rest_headers do
    case Config.settings!().tracker.api_key do
      token when is_binary(token) ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"}
         ]}

      _ ->
        {:error, :missing_github_api_token}
    end
  end

  defp issue_path(issue_id, suffix \\ "") do
    "/issues/#{encode_path_segment(issue_id)}#{suffix}"
  end

  defp encode_path_segment(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
