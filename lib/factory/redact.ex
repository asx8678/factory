defmodule Factory.Redact do
  @moduledoc """
  Takes what identifies a company, its systems or its people out of text given to an
  agent that searches the web (`Factory.Engine`), so it can't end up in a search or a
  URL however the agent is steered: internal hostnames and IP addresses, the tenant part
  of cloud hostnames (the service stays, so the error can still be looked up), email
  addresses, user names given as `user=…`, paths in someone's home folder, IDs, keys,
  tokens and passwords.

  What stays is what a search needs: product names, versions, error codes, the fixed
  part of messages, and public links such as documentation and issue trackers.

  Names only the person knows are theirs (the company's, its products', its customers'):
  they list them in Settings (`"redact_names"` in `Factory.Prefs`), and each is taken
  out as a whole word, whatever its case. User names the text shows where they're
  plainly one (`user=…`, `for user "…"`, `psql -U …`) are learned from it and taken out
  wherever else they appear too; `users_in/1` learns them from a whole run, and the
  run's own folders go by `:paths`, wherever they are.
  """

  # Cloud services whose hostnames start with the customer's own name: the service is
  # kept, the name isn't.
  @tenant_suffixes ~w(
    database.windows.net azurewebsites.net blob.core.windows.net queue.core.windows.net
    table.core.windows.net file.core.windows.net dfs.core.windows.net servicebus.windows.net
    vault.azure.net azurecr.io documents.azure.com redis.cache.windows.net
    cloudapp.azure.com azure-api.net visualstudio.com amazonaws.com cloudfront.net
    herokuapp.com
  )

  # Top-level names only used inside a network.
  @internal ~w(internal local localdomain corp lan intranet private home svc)

  # Where a user name shows: `user=name`, `User ID=name`, `usename='name'`; `--user name`;
  # `psql -U name`; and in database errors, `for user "name"`, `role "name"`.
  @users [
    ~r/\b((?:user(?:[ _-]?(?:name|id))?|usename|rolname|uid|login)\s*=\s*["']?)([^\s;,&"'<>)\]]+)/i,
    ~r/(--user(?:name)?[=\s]+["']?)([^\s:;,&"'<>)\]]+)/i,
    ~r/(\b(?:psql|pg_dump|pg_dumpall|pg_restore|pg_isready|createdb|dropdb|createuser|dropuser|vacuumdb|reindexdb|clusterdb|pgbench)\b[^\n|;&]*?\s-U\s*["']?)([A-Za-z_][\w.$-]*)/,
    ~r/(\b(?:user|role|login)\s+["'])([^"'\s]+)(?=["'])/i,
    ~r/(\s-u\s*["']?)([^\s:"']+)(?=:)/
  ]

  # Roles and accounts a database or system has built in (`pg_read_server_files`,
  # `db_owner`, `mysql.session`): what an error about them needs searched, so they stay.
  @built_in ~r/^(?:pg_|db_|mysql\.|rds_|rdsadmin|azure_|cloudsql|##MS_|NT AUTHORITY\\|NT SERVICE\\)/i

  @doc """
  The text with what identifies anyone replaced by a marker such as `[host]`. Options:

    * `:names` - the words to take out too; by default, the ones saved in Settings
    * `:users` - user names to take out, learned elsewhere (`users_in/1`); the ones the
      text shows itself are always learned
    * `:paths` - folders to take out wherever they are, with the rest of each path
  """
  def text(text, opts \\ [])
  def text(nil, _opts), do: nil

  def text(text, opts) when is_binary(text) do
    names = Keyword.get_lazy(opts, :names, &saved_names/0)
    users = Keyword.get(opts, :users, []) ++ users_in(text)

    text
    |> paths_out(Keyword.get(opts, :paths, []))
    |> secrets()
    |> sub(~r/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, "[email]")
    |> users_given()
    |> sub(
      ~r{(?<![\w.:/~-])(?:/Users|/home)/[^/\s]+(?:/[^\s"'`<>()\[\]]*)?|[A-Za-z]:\\Users\\[^\s"'`<>]+},
      "[path]"
    )
    |> sub(~r/(dev\.azure\.com\/)[^\s\/?#]+/i, "\\1[org]")
    |> sub(tenant_hosts(), "[name].\\1")
    |> sub(internal_hosts(), "[host]")
    |> sub(~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "[id]")
    |> sub(
      ~r/(?<![\d.])(?!(?:127\.0\.0\.1|0\.0\.0\.0)(?![\d.]))(?:\d{1,3}\.){3}\d{1,3}(?![\d.])/,
      "[ip]"
    )
    |> sub(~r/\b(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}\b/i, "[ip]")
    # Shortened with `::` (`fd00::1`), hex on both sides, so `std::io` stays.
    |> sub(
      ~r/(?<![\w:])[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6}::[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,6}(?![\w:])/i,
      "[ip]"
    )
    |> sub(~r/\b[0-9a-f]{24,}\b/i, "[id]")
    |> words_out(users, "[user]")
    |> words_out(names, "[name]")
  end

  @doc """
  The text with only its secrets taken out: keys, tokens, passwords, cookies, and a
  user and password in an address. What identifies people and systems (paths, hosts,
  IDs, commit hashes) stays: for text that leaves Factory on purpose, such as a pull
  request's description (`Factory.Actions`), where those are the point.
  """
  def secrets(nil), do: nil

  def secrets(text) when is_binary(text) do
    text
    |> sub(~r/-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----/s, "[key]")
    |> sub(~r/\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/, "[token]")
    # Keys and tokens known by how they start: AWS, GitHub, GitLab, Slack, OpenAI,
    # Anthropic. A Slack webhook's address is its secret.
    |> sub(~r/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/, "[key]")
    |> sub(
      ~r/\b(?:gh[pousr]_|github_pat_|glpat-|xox[abeprs]-|sk-ant-|sk-proj-)[A-Za-z0-9_-]{10,}|\bsk-[A-Za-z0-9]{32,}\b/,
      "[token]"
    )
    |> sub(~r{(hooks\.slack\.com/(?:services|workflows)/)[\w/-]+}i, "\\1[secret]")
    |> sub(~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{8,}/i, "\\1 [token]")
    # Whatever scheme a header gives (`Authorization: token …`), and a cookie's values.
    |> sub(
      ~r/\b((?:proxy-)?authorization["']?\s*[:=]\s*["']?)(?!(?:Bearer|Basic) \[token\])[^\s"'][^\r\n"']*/i,
      "\\1[token]"
    )
    |> sub(~r/\b((?:set-)?cookie["']?\s*[:=]\s*["']?)[^\r\n"']+/i, "\\1[secret]")
    # A key's name may carry a prefix (`DB_PASSWORD`, `GITHUB_TOKEN`, `x-api-key`), and
    # be quoted, as in JSON (`"password": "…"`).
    |> sub(
      ~r/(?<![A-Za-z0-9])((?:[A-Za-z0-9]+[_-])*(?:password|passwd|pwd|secret|client[_-]?secret|token|api[_-]?key|access[_-]?key|account[_-]?key|shared[_-]?access[_-]?key|private[_-]?key|key[_-]?base|sig|signature)["']?\s*[=:]\s*["']?)(?!(?:yes|no|true|false|null|none)\b)[^\s;,&"'<>)]+/i,
      "\\1[secret]"
    )
    |> sub(~r/((?:\s-u|--user)[=\s]+["']?[^\s:"']+:)[^\s"'<>]+/, "\\1[secret]")
    # A user and password in an address (`postgres://app:s3cret@db`), before the address
    # is taken for an email's.
    |> sub(~r{(\b[a-z][a-z0-9+.-]*://)[^/\s:@]*:[^@\s/]+@}i, "\\1[user]:[secret]@")
  end

  @doc """
  The user names `texts` show (`user=…`, `for user "…"`, `psql -U …`), to take out
  wherever else they appear: the ones that look like an account's (`orders_svc`,
  `svc-etl`, `CORP\\etl`, `adam2`), not plain words or numbers. A plain word may be a
  product the search needs elsewhere (`user=grafana`); it's still taken out where it's
  given as a user, and the person can list it in Settings.
  """
  def users_in(texts) do
    for text <- List.wrap(texts),
        is_binary(text),
        regex <- @users,
        [_, _, name] <- Regex.scan(regex, text),
        name = String.trim_trailing(name, "."),
        String.length(name) >= 3,
        Regex.match?(~r/\p{L}/u, name),
        not String.starts_with?(name, "["),
        not Regex.match?(@built_in, name),
        Regex.match?(~r/[_.\\@\d-]|\p{Ll}\p{Lu}/u, name),
        uniq: true,
        do: name
  end

  @doc "The names saved in Settings to keep out of web searches."
  def saved_names do
    case Factory.Prefs.get("redact_names", []) do
      names when is_list(names) -> names
      _ -> []
    end
  end

  # Longest first, so "Acme Corp" goes whole before "Acme" does.
  defp words_out(text, names, marker) do
    names
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.reduce(text, fn name, text ->
      word =
        Regex.compile!(
          "(?<![\\p{L}\\p{N}_])" <> Regex.escape(name) <> "(?![\\p{L}\\p{N}_])",
          "iu"
        )

      Regex.replace(word, text, marker)
    end)
  end

  # Each folder with the rest of its path: `/srv/app/logs/x.log`, not `/srv/application`.
  defp paths_out(text, paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> Path.expand() |> String.trim_trailing("/")))
    |> Enum.reject(&(&1 in ["", "/"]))
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.reduce(text, fn path, text ->
      regex = Regex.compile!(Regex.escape(path) <> ~S{(?![\w.-])(?:/[^\s"'`<>()\[\]]*)?})
      Regex.replace(regex, text, "[path]")
    end)
  end

  defp sub(text, regex, marker), do: Regex.replace(regex, text, marker)

  # Each user name where it's given as one, but for the built-in ones.
  defp users_given(text),
    do: Enum.reduce(@users, text, fn regex, text -> Regex.replace(regex, text, &user/3) end)

  defp user(whole, lead, name),
    do: if(Regex.match?(@built_in, name), do: whole, else: lead <> "[user]")

  defp tenant_hosts do
    suffixes = Enum.map_join(@tenant_suffixes, "|", &Regex.escape/1)
    Regex.compile!("\\b[a-z0-9][a-z0-9-]*(?:\\.[a-z0-9-]+)*\\.(#{suffixes})\\b", "i")
  end

  defp internal_hosts do
    Regex.compile!("\\b(?:[a-z0-9][a-z0-9-]*\\.)+(?:#{Enum.join(@internal, "|")})\\b", "i")
  end
end
