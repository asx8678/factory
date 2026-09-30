defmodule Factory.Redact do
  @moduledoc """
  Takes what identifies a company, its systems or its people out of text given to an
  agent that searches the web (`Factory.Engine`), so it can't end up in a search or a
  URL however the agent is steered: internal hostnames and IP addresses, the tenant part
  of cloud hostnames (the service stays, so the error can still be looked up), email
  addresses, IDs, keys, tokens and passwords.

  What stays is what a search needs: product names, versions, error codes, the fixed
  part of messages, and public links such as documentation and issue trackers.
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

  @doc "The text with what identifies anyone replaced by a marker such as `[host]`."
  def text(nil), do: nil

  def text(text) when is_binary(text) do
    text
    |> sub(~r/-----BEGIN [A-Z ]+-----.*?-----END [A-Z ]+-----/s, "[key]")
    |> sub(~r/\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/, "[token]")
    |> sub(~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{8,}/i, "\\1 [token]")
    |> sub(
      ~r/\b((?:password|passwd|pwd|secret|client[_-]?secret|token|api[_-]?key|access[_-]?key|account[_-]?key|shared[_-]?access[_-]?key|sig|signature)\s*[=:]\s*)[^\s;,&"'<>]+/i,
      "\\1[secret]"
    )
    |> sub(~r/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, "[email]")
    |> sub(~r/(dev\.azure\.com\/)[^\s\/?#]+/i, "\\1[org]")
    |> sub(tenant_hosts(), "[name].\\1")
    |> sub(internal_hosts(), "[host]")
    |> sub(~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "[id]")
    |> sub(
      ~r/(?<![\d.])(?!(?:127\.0\.0\.1|0\.0\.0\.0)(?![\d.]))(?:\d{1,3}\.){3}\d{1,3}(?![\d.])/,
      "[ip]"
    )
    |> sub(~r/\b(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}\b/i, "[ip]")
    |> sub(~r/\b[0-9a-f]{24,}\b/i, "[id]")
  end

  defp sub(text, regex, marker), do: Regex.replace(regex, text, marker)

  defp tenant_hosts do
    suffixes = Enum.map_join(@tenant_suffixes, "|", &Regex.escape/1)
    Regex.compile!("\\b[a-z0-9][a-z0-9-]*(?:\\.[a-z0-9-]+)*\\.(#{suffixes})\\b", "i")
  end

  defp internal_hosts do
    Regex.compile!("\\b(?:[a-z0-9][a-z0-9-]*\\.)+(?:#{Enum.join(@internal, "|")})\\b", "i")
  end
end
